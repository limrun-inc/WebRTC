/*
 *  Copyright (c) 2018 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 *
 */

#import "RTCVideoEncoderH265.h"

#import <VideoToolbox/VideoToolbox.h>
#include <vector>

#import "RTCCodecSpecificInfoH265.h"
// #import "api/peerconnection/RTCRtpFragmentationHeader+Private.h"
#import "api/peerconnection/RTCVideoCodecInfo+Private.h"
#import "base/RTCI420Buffer.h"
#import "base/RTCVideoFrame.h"
#import "base/RTCVideoFrameBuffer.h"
#import "components/video_frame_buffer/RTCCVPixelBuffer.h"
#import "helpers.h"
#if defined(WEBRTC_IOS)
#import "helpers/UIDevice+RTCDevice.h"
#endif
#import "RTCH265ProfileLevelId.h"

#include "common_video/h265/h265_bitstream_parser.h"
#include "common_video/include/bitrate_adjuster.h"
#include "libyuv/convert_from.h"
#include "modules/include/module_common_types.h"
#include "modules/video_coding/include/video_error_codes.h"
#include "rtc_base/buffer.h"
#include "rtc_base/logging.h"
#include "rtc_base/time_utils.h"
#include "sdk/objc/Framework/Classes/VideoToolbox/nalu_rewriter.h"
#include "system_wrappers/include/clock.h"

@interface RTC_OBJC_TYPE (RTCVideoEncoderH265) ()

- (void)frameWasEncoded:(OSStatus)status
                  flags:(VTEncodeInfoFlags)infoFlags
           sampleBuffer:(CMSampleBufferRef)sampleBuffer
                  width:(int32_t)width
                 height:(int32_t)height
           renderTimeMs:(int64_t)renderTimeMs
              timestamp:(uint32_t)timestamp
               rotation:(RTC_OBJC_TYPE(RTCVideoRotation))rotation;
@end

namespace {  // anonymous namespace

// These thresholds deviate from the default h265 QP thresholds, as they
// have been found to work better on devices that support VideoToolbox
const int kLowh265QpThreshold = 28;
const int kHighh265QpThreshold = 39;
const int kBitsPerByte = 8;

const OSType kNV12PixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;

// Limit to the average bitrate to the video bitrate.
// Use this to tweak ratio between data rate and peak bitrate.
// TODO(magjed): Set this carefully based on experiments.
const float kLimitToAverageBitRateFactor = 1.5f;

typedef NS_ENUM(NSInteger, RTC_OBJC_TYPE(RTCVideoEncodeMode)) {
  RTC_OBJC_TYPE(RTCVideoEncodeModeVariable) = 0,
  RTC_OBJC_TYPE(RTCVideoEncodeModeConstant) = 1,
};

NSArray *CreateRateLimitArray(uint32_t computedBitrateBps, RTC_OBJC_TYPE(RTCVideoEncodeMode) mode) {
  switch (mode) {
    case RTC_OBJC_TYPE(RTCVideoEncodeModeVariable): {
      // 5 seconds should be an okay interval for VBR to enforce the long-term
      // limit.
      float avgInterval = 5.0;
      uint32_t avgBytesPerSecond = computedBitrateBps / kBitsPerByte * avgInterval;
      // And the peak bitrate is measured per-second in a way similar to CBR.
      float peakInterval = 1.0;
      uint32_t peakBytesPerSecond =
          computedBitrateBps * kLimitToAverageBitRateFactor / kBitsPerByte;
      return @[ @(peakBytesPerSecond), @(peakInterval), @(avgBytesPerSecond), @(avgInterval) ];
    }
    case RTC_OBJC_TYPE(RTCVideoEncodeModeConstant): {
      // CBR should be enforced with granularity of a second.
      float targetInterval = 1.0;
      int32_t targetBitrate = computedBitrateBps / kBitsPerByte;
      return @[ @(targetBitrate), @(targetInterval) ];
    }
  }
}

// Struct that we pass to the encoder per frame to encode. We receive it again
// in the encoder callback.
struct API_AVAILABLE(ios(11.0)) RTC_OBJC_TYPE(RTCFrameEncodeParams) {
  RTC_OBJC_TYPE(RTCFrameEncodeParams)(RTC_OBJC_TYPE(RTCVideoEncoderH265) * e, int32_t w, int32_t h,
                                      int64_t rtms, uint32_t ts, RTC_OBJC_TYPE(RTCVideoRotation) r)
      : encoder(e), width(w), height(h), render_time_ms(rtms), timestamp(ts), rotation(r) {}

  RTC_OBJC_TYPE(RTCVideoEncoderH265) * encoder;
  int32_t width;
  int32_t height;
  int64_t render_time_ms;
  uint32_t timestamp;
  RTC_OBJC_TYPE(RTCVideoRotation) rotation;
};

// We receive I420Frames as input, but we need to feed CVPixelBuffers into the
// encoder. This performs the copy and format conversion.
// TODO(tkchin): See if encoder will accept i420 frames and compare performance.
bool CopyVideoFrameToPixelBuffer(id<RTC_OBJC_TYPE(RTCI420Buffer)> frameBuffer,
                                 CVPixelBufferRef pixelBuffer) {
  RTC_DCHECK(pixelBuffer);
  RTC_DCHECK_EQ(CVPixelBufferGetPixelFormatType(pixelBuffer),
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
  RTC_DCHECK_EQ(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0), frameBuffer.height);
  RTC_DCHECK_EQ(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), frameBuffer.width);

  CVReturn cvRet = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
  if (cvRet != kCVReturnSuccess) {
    RTC_LOG(LS_ERROR) << "Failed to lock base address: " << cvRet;
    return false;
  }

  uint8_t* dstY = reinterpret_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
  int dstStrideY = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
  uint8_t* dstUV = reinterpret_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
  int dstStrideUV = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
  // Convert I420 to NV12.
  int ret =
      libyuv::I420ToNV12(frameBuffer.dataY, frameBuffer.strideY, frameBuffer.dataU,
                         frameBuffer.strideU, frameBuffer.dataV, frameBuffer.strideV, dstY,
                         dstStrideY, dstUV, dstStrideUV, frameBuffer.width, frameBuffer.height);
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
  if (ret) {
    RTC_LOG(LS_ERROR) << "Error converting I420 VideoFrame to NV12 :" << ret;
    return false;
  }
  return true;
}

CVPixelBufferRef CreatePixelBuffer(CVPixelBufferPoolRef pixel_buffer_pool) {
  if (!pixel_buffer_pool) {
    RTC_LOG(LS_ERROR) << "Failed to get pixel buffer pool.";
    return nullptr;
  }
  CVPixelBufferRef pixel_buffer;
  CVReturn ret = CVPixelBufferPoolCreatePixelBuffer(nullptr, pixel_buffer_pool, &pixel_buffer);
  if (ret != kCVReturnSuccess) {
    RTC_LOG(LS_ERROR) << "Failed to create pixel buffer: " << ret;
    // We probably want to drop frames here, since failure probably means
    // that the pool is empty.
    return nullptr;
  }
  return pixel_buffer;
}

// This is the callback function that VideoToolbox calls when encode is
// complete. From inspection this happens on its own queue.
void compressionOutputCallback(void* encoder, void* params, OSStatus status,
                               VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer)
    API_AVAILABLE(ios(11.0)) {
  RTC_CHECK(params);
  std::unique_ptr<RTC_OBJC_TYPE(RTCFrameEncodeParams)> encodeParams(
      reinterpret_cast<RTC_OBJC_TYPE(RTCFrameEncodeParams)*>(params));
  RTC_CHECK(encodeParams->encoder);
  [encodeParams->encoder frameWasEncoded:status
                                   flags:infoFlags
                            sampleBuffer:sampleBuffer
                                   width:encodeParams->width
                                  height:encodeParams->height
                            renderTimeMs:encodeParams->render_time_ms
                               timestamp:encodeParams->timestamp
                                rotation:encodeParams->rotation];
}
}  // namespace

@implementation RTC_OBJC_TYPE (RTCVideoEncoderH265) {
  RTC_OBJC_TYPE(RTCVideoCodecInfo) * _codecInfo;
  std::unique_ptr<webrtc::BitrateAdjuster> _bitrateAdjuster;
  uint32_t _targetBitrateBps;
  uint32_t _targetFrameRate;
  uint32_t _encoderBitrateBps;
  uint32_t _encoderFrameRate;
  unsigned int _maxQP;
  unsigned int _minBitrate;
  unsigned int _maxBitrate;
  CFStringRef _profile;
  RTCVideoEncoderCallback _callback;
  int32_t _width;
  int32_t _height;
  VTCompressionSessionRef _compressionSession;
  RTC_OBJC_TYPE(RTCVideoCodecMode) _mode;
  RTC_OBJC_TYPE(RTCVideoEncodeMode) _encodeMode;
  int framesLeft;
  std::vector<uint8_t> _nv12ScaleBuffer;
  webrtc::H265BitstreamParser _h265BitstreamParser;
}

// .5 is set as a mininum to prevent overcompensating for large temporary
// overshoots. We don't want to degrade video quality too badly.
// .95 is set to prevent oscillations. When a lower bitrate is set on the
// encoder than previously set, its output seems to have a brief period of
// drastically reduced bitrate, so we want to avoid that. In steady state
// conditions, 0.95 seems to give us better overall bitrate over long periods
// of time.
- (instancetype)initWithCodecInfo:(RTC_OBJC_TYPE(RTCVideoCodecInfo) *)codecInfo {
  NSParameterAssert(codecInfo);
  self = [super init];
  if (self) {
    _codecInfo = codecInfo;
    _bitrateAdjuster.reset(new webrtc::BitrateAdjuster(.5, .95));
    // AnnexB and low latency are always enabled.
    RTC_CHECK([codecInfo.name isEqualToString:RTC_CONSTANT_TYPE(RTCVideoCodecH265Name)]);
  }

  return self;
}

- (void)dealloc {
  [self destroyCompressionSession];
}

- (NSInteger)startEncodeWithSettings:(RTC_OBJC_TYPE(RTCVideoEncoderSettings) *)settings
                       numberOfCores:(int)numberOfCores {
  RTC_DCHECK(settings);
  RTC_DCHECK([settings.name isEqualToString:RTC_CONSTANT_TYPE(RTCVideoCodecH265Name)]);

  _width = settings.width;
  _height = settings.height;
  _mode = settings.mode;
  _maxQP = settings.qpMax;

  // Determine encode mode (VBR or CBR) based on codec mode
  if (_mode == RTC_OBJC_TYPE(RTCVideoCodecModeScreensharing)) {
    _encodeMode = RTC_OBJC_TYPE(RTCVideoEncodeModeConstant);
  } else {
    _encodeMode = RTC_OBJC_TYPE(RTCVideoEncodeModeVariable);
  }

  _minBitrate = settings.minBitrate * 1000;  // minBitrate is in kbps.
  _maxBitrate = settings.maxBitrate * 1000;  // maxBitrate is in kbps.

  // We can only set average bitrate on the HW encoder.
  if (_encodeMode == RTC_OBJC_TYPE(RTCVideoEncodeModeConstant)) {
    _targetBitrateBps = _maxBitrate;
  } else {
    _targetBitrateBps = settings.startBitrate * 1000;  // startBitrate is in kbps.
  }
  _bitrateAdjuster->SetTargetBitrateBps(_targetBitrateBps);
  _targetFrameRate = settings.maxFramerate;
  _encoderBitrateBps = 0;
  _encoderFrameRate = 0;

  return [self resetCompressionSession];
}

// AnnexB and low latency are always enabled; setters removed.

- (NSInteger)encode:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame
    codecSpecificInfo:(nullable id<RTC_OBJC_TYPE(RTCCodecSpecificInfo)>)codecSpecificInfo
           frameTypes:(NSArray<NSNumber*>*)frameTypes {
  if (!_callback || !_compressionSession) {
    return WEBRTC_VIDEO_CODEC_UNINITIALIZED;
  }
  BOOL isKeyframeRequired = NO;

  // Get a pixel buffer from the pool and copy frame data over.
  CVPixelBufferPoolRef pixelBufferPool =
      VTCompressionSessionGetPixelBufferPool(_compressionSession);

#if defined(WEBRTC_IOS)
  if (!pixelBufferPool) {
    // Kind of a hack. On backgrounding, the compression session seems to get
    // invalidated, which causes this pool call to fail when the application
    // is foregrounded and frames are being sent for encoding again.
    // Resetting the session when this happens fixes the issue.
    // In addition we request a keyframe so video can recover quickly.
    [self resetCompressionSession];
    pixelBufferPool = VTCompressionSessionGetPixelBufferPool(_compressionSession);
    isKeyframeRequired = YES;
    RTC_LOG(LS_INFO) << "Resetting compression session due to invalid pool.";
  }
#endif

  CVPixelBufferRef pixelBuffer = nullptr;
  if ([frame.buffer isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
    // Native frame buffer
    RTC_OBJC_TYPE(RTCCVPixelBuffer)* rtcPixelBuffer =
        (RTC_OBJC_TYPE(RTCCVPixelBuffer)*)frame.buffer;
    if (![rtcPixelBuffer requiresCropping]) {
      // This pixel buffer might have a higher resolution than what the
      // compression session is configured to. The compression session can
      // handle that and will output encoded frames in the configured
      // resolution regardless of the input pixel buffer resolution.
      pixelBuffer = rtcPixelBuffer.pixelBuffer;
      CVBufferRetain(pixelBuffer);
    } else {
      // Cropping required, we need to crop and scale to a new pixel buffer.
      pixelBuffer = CreatePixelBuffer(pixelBufferPool);
      if (!pixelBuffer) {
        return WEBRTC_VIDEO_CODEC_ERROR;
      }
      int dstWidth = CVPixelBufferGetWidth(pixelBuffer);
      int dstHeight = CVPixelBufferGetHeight(pixelBuffer);
      if ([rtcPixelBuffer requiresScalingToWidth:dstWidth height:dstHeight]) {
        const int requiredSize = [rtcPixelBuffer bufferSizeForCroppingAndScalingToWidth:dstWidth
                                                                                 height:dstHeight];
        if (static_cast<int>(_nv12ScaleBuffer.size()) < requiredSize) {
          _nv12ScaleBuffer.resize(requiredSize);
        }
      }
      if (![rtcPixelBuffer cropAndScaleTo:pixelBuffer withTempBuffer:_nv12ScaleBuffer.data()]) {
        return WEBRTC_VIDEO_CODEC_ERROR;
      }
    }
  }

  if (!pixelBuffer) {
    // We did not have a native frame buffer
    RTC_DCHECK_EQ(frame.width, _width);
    RTC_DCHECK_EQ(frame.height, _height);

    pixelBuffer = CreatePixelBuffer(pixelBufferPool);
    if (!pixelBuffer) {
      return WEBRTC_VIDEO_CODEC_ERROR;
    }
    RTC_DCHECK(pixelBuffer);
    if (!CopyVideoFrameToPixelBuffer([frame.buffer toI420], pixelBuffer)) {
      RTC_LOG(LS_ERROR) << "Failed to copy frame data.";
      CVBufferRelease(pixelBuffer);
      return WEBRTC_VIDEO_CODEC_ERROR;
    }
  }

  // Check if we need a keyframe.
  if (!isKeyframeRequired && frameTypes) {
    for (NSNumber* frameType in frameTypes) {
      if ((RTC_OBJC_TYPE(RTCFrameType))frameType.intValue ==
          RTC_OBJC_TYPE(RTCFrameTypeVideoFrameKey)) {
        isKeyframeRequired = YES;
        break;
      }
    }
  }

  CMTime presentationTimeStamp = CMTimeMake(frame.timeStampNs / rtc::kNumNanosecsPerMillisec, 1000);
  CFDictionaryRef frameProperties = nullptr;
  if (isKeyframeRequired) {
    // Reuse a static dictionary to avoid per-frame allocations.
    static CFDictionaryRef forceKeyframeProps = []() {
      CFTypeRef keys[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
      CFTypeRef values[] = {kCFBooleanTrue};
      CFDictionaryRef dict = CreateCFTypeDictionary(keys, values, 1);
      // Intentionally leaked for process lifetime reuse.
      return dict;
    }();
    frameProperties = forceKeyframeProps;
  }

  std::unique_ptr<RTC_OBJC_TYPE(RTCFrameEncodeParams)> encodeParams;
  encodeParams.reset(new RTC_OBJC_TYPE(RTCFrameEncodeParams)(
      self, _width, _height, frame.timeStampNs / rtc::kNumNanosecsPerMillisec, frame.timeStamp,
      frame.rotation));

  // Update encoder bitrate and frame rate if needed.
  [self updateEncoderBitrateAndFrameRate];

  OSStatus status = VTCompressionSessionEncodeFrame(
      _compressionSession, pixelBuffer, presentationTimeStamp, kCMTimeInvalid, frameProperties,
      encodeParams.release(), nullptr);
  // Do not release `frameProperties` when using the cached dictionary.
  if (pixelBuffer) {
    CVBufferRelease(pixelBuffer);
  }

  if (status == kVTInvalidSessionErr) {
    // This error occurs when entering foreground after backgrounding the app or on macOS.
    RTC_LOG(LS_ERROR) << "Invalid compression session, resetting.";
    [self resetCompressionSessionWithPixelFormat:[self pixelFormatOfFrame:frame]];
    return WEBRTC_VIDEO_CODEC_NO_OUTPUT;
  } else if (status == kVTVideoEncoderMalfunctionErr) {
    // Sometimes the encoder malfunctions and needs to be restarted.
    RTC_LOG(LS_ERROR) << "Encountered video encoder malfunction error. "
                         "Resetting compression session.";
    [self resetCompressionSessionWithPixelFormat:[self pixelFormatOfFrame:frame]];
    return WEBRTC_VIDEO_CODEC_NO_OUTPUT;
  } else if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to encode frame with code: " << status;
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  return WEBRTC_VIDEO_CODEC_OK;
}

- (void)setCallback:(RTCVideoEncoderCallback)callback {
  _callback = callback;
}

- (int)setBitrate:(uint32_t)bitrateKbit framerate:(uint32_t)framerate {
  _targetBitrateBps = 1000 * bitrateKbit;
  _bitrateAdjuster->SetTargetBitrateBps(_targetBitrateBps);
  if (framerate > 0) {
    _targetFrameRate = framerate;
  }
  [self updateEncoderBitrateAndFrameRate];
  return WEBRTC_VIDEO_CODEC_OK;
}

- (NSInteger)resolutionAlignment {
  return 1;
}

- (BOOL)applyAlignmentToAllSimulcastLayers {
  return NO;
}

- (BOOL)supportsNativeHandle {
  return YES;
}

#pragma mark - Private

- (NSInteger)releaseEncoder {
  // Need to destroy so that the session is invalidated and won't use the
  // callback anymore. Do not remove callback until the session is invalidated
  // since async encoder callbacks can occur until invalidation.
  [self destroyCompressionSession];
  _callback = nullptr;
  return WEBRTC_VIDEO_CODEC_OK;
}

- (OSType)pixelFormatOfFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
  // Use NV12 for non-native frames.
  if ([frame.buffer isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
    RTC_OBJC_TYPE(RTCCVPixelBuffer) *rtcPixelBuffer =
        (RTC_OBJC_TYPE(RTCCVPixelBuffer) *)frame.buffer;
    return CVPixelBufferGetPixelFormatType(rtcPixelBuffer.pixelBuffer);
  }

  return kNV12PixelFormat;
}

- (int)resetCompressionSession {
  return [self resetCompressionSessionWithPixelFormat:kNV12PixelFormat];
}

- (int)resetCompressionSessionWithPixelFormat:(OSType)framePixelFormat {
  [self destroyCompressionSession];

  // Set source image buffer attributes. These attributes will be present on
  // buffers retrieved from the encoder's pixel buffer pool.
  const size_t attributesSize = 3;
  CFTypeRef keys[attributesSize] = {
#if defined(WEBRTC_MAC) || defined(WEBRTC_MAC_CATALYST)
      kCVPixelBufferOpenGLCompatibilityKey,
#elif defined(WEBRTC_IOS)
      kCVPixelBufferOpenGLESCompatibilityKey,
#endif
      kCVPixelBufferIOSurfacePropertiesKey, kCVPixelBufferPixelFormatTypeKey};
  CFDictionaryRef ioSurfaceValue = CreateCFTypeDictionary(nullptr, nullptr, 0);
  int64_t pixelFormat = framePixelFormat;
  CFNumberRef pixelFormatNumber = CFNumberCreate(nullptr, kCFNumberLongType, &pixelFormat);
  CFTypeRef values[attributesSize] = {kCFBooleanTrue, ioSurfaceValue, pixelFormatNumber};
  CFDictionaryRef sourceAttributes = CreateCFTypeDictionary(keys, values, attributesSize);
  if (ioSurfaceValue) {
    CFRelease(ioSurfaceValue);
    ioSurfaceValue = nullptr;
  }
  if (pixelFormatNumber) {
    CFRelease(pixelFormatNumber);
    pixelFormatNumber = nullptr;
  }
  CFMutableDictionaryRef encoder_specs = CFDictionaryCreateMutable(
      nullptr, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

  if (@available(iOS 17.4, macCatalyst 17.4, macOS 10.9, tvOS 17.4, visionOS 1.1, *)) {
    CFDictionarySetValue(encoder_specs,
                         kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder,
                         kCFBooleanTrue);
  }

  if (@available(iOS 14.5, macCatalyst 14.5, macOS 11.3, tvOS 14.5, visionOS 1.0, *)) {
    CFDictionarySetValue(encoder_specs, kVTVideoEncoderSpecification_EnableLowLatencyRateControl,
                         kCFBooleanTrue);
  }

  OSStatus status =
      VTCompressionSessionCreate(nullptr,  // use default allocator
                                 _width, _height, kCMVideoCodecType_HEVC,
                                 encoder_specs,  // use hardware accelerated encoder if available
                                 sourceAttributes,
                                 nullptr,  // use default compressed data allocator
                                 compressionOutputCallback, nullptr, &_compressionSession);
  if (status != noErr) {
    status =
        VTCompressionSessionCreate(nullptr,  // use default allocator
                                   _width, _height, kCMVideoCodecType_HEVC,
                                   encoder_specs,  // use hardware accelerated encoder if available
                                   sourceAttributes,
                                   nullptr,  // use default compressed data allocator
                                   compressionOutputCallback, nullptr, &_compressionSession);
  }
  if (sourceAttributes) {
    CFRelease(sourceAttributes);
    sourceAttributes = nullptr;
  }
  if (encoder_specs) {
    CFRelease(encoder_specs);
    encoder_specs = nullptr;
  }
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to create compression session: " << status;
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  if (@available(iOS 17.4, macCatalyst 17.4, macOS 10.9, tvOS 17.4, visionOS 1.1, *)) {
    CFBooleanRef hwaccl_enabled = nullptr;
    status = VTSessionCopyProperty(_compressionSession,
                                   kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                   kCFAllocatorDefault, &hwaccl_enabled);
    if (status == noErr && (CFBooleanGetValue(hwaccl_enabled))) {
      RTC_LOG(LS_INFO) << "Compression session created with hw accl enabled";
    } else {
      RTC_LOG(LS_INFO) << "Compression session created with hw accl disabled";
    }
  }
  [self configureCompressionSession];
  return WEBRTC_VIDEO_CODEC_OK;
}

- (void)configureCompressionSession {
  RTC_DCHECK(_compressionSession);
  SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_RealTime, true);
  // Sacrifice encoding speed over quality when necessary
  if (@available(iOS 14.0, macOS 11.0, *)) {
    SetVTSessionProperty(
        _compressionSession, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true);
  }
  // SetVTSessionProperty(_compressionSession,
  // kVTCompressionPropertyKey_ProfileLevel, _profile);
  SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_AllowFrameReordering, false);
  // Set maximum QP for screen sharing mode on supported OS versions.
  // https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_maxallowedframeqp
  if (@available(iOS 15.0, macOS 12.0, *)) {
    // Only enable for screen sharing and let VideoToolbox do the optimizing as much as possible.
    if (_mode == RTC_OBJC_TYPE(RTCVideoCodecModeScreensharing)) {
      // Use configured maxQP if available, otherwise fall back to default threshold
      unsigned int maxQP = _maxQP > 0 ? _maxQP : kHighh265QpThreshold;
      RTC_LOG(LS_INFO) << "Configuring VideoToolbox to use maxQP: " << maxQP
                       << " mode: " << _mode;
      SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_MaxAllowedFrameQP, maxQP);
    }
  }
  // Reduce the encoder's internal buffering for lower latency if available.
  // kVTCompressionPropertyKey_MaxFrameDelayCount is supported on macOS/iOS for HEVC.
  // SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_MaxFrameDelayCount, 1);
  
  // Set a relatively large value for keyframe emission (7200 frames or 4 minutes).
  SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, 7200);
  SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                       240);
  OSStatus status = VTCompressionSessionPrepareToEncodeFrames(_compressionSession);
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Compression session failed to prepare encode frames.";
  }
}

- (void)destroyCompressionSession {
  if (_compressionSession) {
    VTCompressionSessionInvalidate(_compressionSession);
    CFRelease(_compressionSession);
    _compressionSession = nullptr;
  }
}

- (NSString*)implementationName {
  return @"VideoToolbox";
}

- (void)updateEncoderBitrateAndFrameRate {
  // If no compression session simply return
  if (!_compressionSession) {
    return;
  }
  
  OSStatus status = noErr;
  
  // Get the adjusted bitrate from the bitrate adjuster
  uint32_t computedBitrateBps = _bitrateAdjuster->GetAdjustedBitrateBps();
  
  // Set frame rate (for H.265, we just use the target frame rate directly)
  uint32_t computedFrameRate = _targetFrameRate;
  
  if (computedFrameRate != _encoderFrameRate) {
    status = VTSessionSetProperty(_compressionSession,
                                  kVTCompressionPropertyKey_ExpectedFrameRate,
                                  (__bridge CFTypeRef) @(computedFrameRate));
    // Ensure the frame rate was set successfully
    if (status != noErr) {
      RTC_LOG(LS_ERROR) << "Failed to set frame rate: " << computedFrameRate
                        << " error: " << status;
    } else {
      RTC_LOG(LS_INFO) << "Did update encoder frame rate: " << computedFrameRate;
    }
    _encoderFrameRate = computedFrameRate;
  }
  
  // Set bitrate
  if (computedBitrateBps != _encoderBitrateBps) {
    status = VTSessionSetProperty(_compressionSession,
                                  kVTCompressionPropertyKey_AverageBitRate,
                                  (__bridge CFTypeRef) @(computedBitrateBps));
    
    // Ensure the bitrate was set successfully
    if (status != noErr) {
      RTC_LOG(LS_ERROR) << "Failed to update encoder bitrate: " << computedBitrateBps
                        << " error: " << status;
    } else {
      RTC_LOG(LS_INFO) << "Did update encoder bitrate: " << computedBitrateBps;
    }
    
    status = VTSessionSetProperty(
        _compressionSession,
        kVTCompressionPropertyKey_DataRateLimits,
        (__bridge CFArrayRef)CreateRateLimitArray(computedBitrateBps, _encodeMode));
    if (status != noErr) {
      RTC_LOG(LS_ERROR) << "Failed to update encoder data rate limits";
    } else {
      RTC_LOG(LS_INFO) << "Did update encoder data rate limits";
    }
    
    _encoderBitrateBps = computedBitrateBps;
  }
}

- (void)frameWasEncoded:(OSStatus)status
                  flags:(VTEncodeInfoFlags)infoFlags
           sampleBuffer:(CMSampleBufferRef)sampleBuffer
                  width:(int32_t)width
                 height:(int32_t)height
           renderTimeMs:(int64_t)renderTimeMs
              timestamp:(uint32_t)timestamp
               rotation:(RTC_OBJC_TYPE(RTCVideoRotation))rotation {
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "h265 encode failed.";
    return;
  }
  if (infoFlags & kVTEncodeInfo_FrameDropped) {
    RTC_LOG(LS_INFO) << "h265 encoder dropped a frame.";
    return;
  }

  BOOL isKeyframe = NO;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, 0);
  if (attachments != nullptr && CFArrayGetCount(attachments)) {
    CFDictionaryRef attachment =
        static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
    isKeyframe = !CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
  }

  if (isKeyframe) {
    RTC_LOG(LS_INFO) << "Generated keyframe";
  }

  __block std::unique_ptr<webrtc::Buffer> buffer = std::make_unique<webrtc::Buffer>();
  // Always using AnnexB format for bitstream parsing and output
  if (!webrtc::H265CMSampleBufferToAnnexBBuffer(sampleBuffer, isKeyframe, buffer.get())) {
    RTC_LOG(LS_WARNING) << "Unable to parse H265 encoded buffer";
    return;
  }

  RTC_OBJC_TYPE(RTCEncodedImage)* frame = [[RTC_OBJC_TYPE(RTCEncodedImage) alloc] init];
  // This assumes ownership of `buffer` and is responsible for freeing it when done.
  frame.buffer = [[NSData alloc] initWithBytesNoCopy:buffer->data()
                                              length:buffer->size()
                                         deallocator:^(void* bytes, NSUInteger size) {
                                           buffer.reset();
                                         }];
  frame.encodedWidth = width;
  frame.encodedHeight = height;
  frame.frameType = isKeyframe ? RTC_OBJC_TYPE(RTCFrameTypeVideoFrameKey)
                               : RTC_OBJC_TYPE(RTCFrameTypeVideoFrameDelta);
  frame.captureTimeMs = renderTimeMs;
  frame.timeStamp = timestamp;
  frame.rotation = rotation;
  frame.contentType = (_mode == RTC_OBJC_TYPE(RTCVideoCodecModeScreensharing))
                          ? RTC_OBJC_TYPE(RTCVideoContentTypeScreenshare)
                          : RTC_OBJC_TYPE(RTCVideoContentTypeUnspecified);
  frame.flags = webrtc::VideoSendTiming::kInvalid;

  // Always using AnnexB format for QP parsing
  _h265BitstreamParser.ParseBitstream(*buffer);
  auto qp = _h265BitstreamParser.GetLastSliceQp();
  frame.qp = @(qp.value_or(0));

  BOOL res = _callback(frame, [[RTC_OBJC_TYPE(RTCCodecSpecificInfoH265) alloc] init]);
  if (!res) {
    RTC_LOG(LS_ERROR) << "Encode callback failed.";
    return;
  }
  _bitrateAdjuster->Update(frame.buffer.length);
}

- (RTC_OBJC_TYPE(RTCVideoEncoderQpThresholds) *)scalingSettings {
  return [[RTC_OBJC_TYPE(RTCVideoEncoderQpThresholds) alloc]
      initWithThresholdsLow:kLowh265QpThreshold
                       high:kHighh265QpThreshold];
}

- (void)flush {
  if (_compressionSession) VTCompressionSessionCompleteFrames(_compressionSession, kCMTimeInvalid);
}

@end