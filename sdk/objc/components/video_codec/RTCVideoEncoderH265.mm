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

// Struct that we pass to the encoder per frame to encode. We receive it again
// in the encoder callback.
struct RTC_OBJC_TYPE(RTCFrameEncodeParams) {
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

// This is the callback function that VideoToolbox calls when encode is
// complete. From inspection this happens on its own queue.
void compressionOutputCallback(void* encoder, void* params, OSStatus status,
                               VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer)  {
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
  uint32_t _encoderBitrateBps;
  CFStringRef _profile;
  RTCVideoEncoderCallback _callback;
  int32_t _width;
  int32_t _height;
  VTCompressionSessionRef _compressionSession;
  RTC_OBJC_TYPE(RTCVideoCodecMode) _mode;
  int framesLeft;
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

  // We can only set average bitrate on the HW encoder.
  _targetBitrateBps = settings.startBitrate;
  _bitrateAdjuster->SetTargetBitrateBps(_targetBitrateBps);

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
  RTC_OBJC_TYPE(RTCCVPixelBuffer)* rtcPixelBuffer = (RTC_OBJC_TYPE(RTCCVPixelBuffer)*)frame.buffer;
  CVPixelBufferRef pixelBuffer = rtcPixelBuffer.pixelBuffer;
  CVBufferRetain(pixelBuffer);
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

  // Update the bitrate if needed.
  [self setBitrateBps:_bitrateAdjuster->GetAdjustedBitrateBps()];

  OSStatus status = VTCompressionSessionEncodeFrame(
      _compressionSession, pixelBuffer, presentationTimeStamp, kCMTimeInvalid, frameProperties,
      encodeParams.release(), nullptr);
  // Do not release `frameProperties` when using the cached dictionary.
  if (pixelBuffer) {
    CVBufferRelease(pixelBuffer);
  }
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to encode frame with code: " << status;
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  //VTCompressionSessionCompleteFrames(_compressionSession, presentationTimeStamp);
  return WEBRTC_VIDEO_CODEC_OK;
}

- (void)setCallback:(RTCVideoEncoderCallback)callback {
  _callback = callback;
}

- (int)setBitrate:(uint32_t)bitrateKbit framerate:(uint32_t)framerate {
  _targetBitrateBps = 1000 * bitrateKbit;
  _bitrateAdjuster->SetTargetBitrateBps(_targetBitrateBps);
  [self setBitrateBps:_bitrateAdjuster->GetAdjustedBitrateBps()];
  return WEBRTC_VIDEO_CODEC_OK;
}

- (NSInteger)resolutionAlignment {
  return 16;
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

- (NSDictionary*)getEncoderSettingsForPreset {
  if (!_compressionSession) {
    return nil;
  }

  CFDictionaryRef supportedPresetDictionaries = nullptr;
  OSStatus status = VTSessionCopyProperty(_compressionSession, 
                                         kVTCompressionPropertyKey_SupportedPresetDictionaries,
                                         kCFAllocatorDefault, 
                                         &supportedPresetDictionaries);

  NSDictionary* encoderSettings = nil;
  
  if (status == noErr && supportedPresetDictionaries) {
    NSDictionary* presetDict = (__bridge_transfer NSDictionary*)supportedPresetDictionaries;
    
    // Use the HighSpeed preset for WebRTC low-latency encoding
    // This preset prioritizes encoding speed, disables frame reordering,
    // and is optimized for real-time video conferencing
    NSString* presetKey = @"HighSpeed";
    id presetValue = presetDict[presetKey];
    
    if ([presetValue isKindOfClass:[NSDictionary class]]) {
      encoderSettings = (NSDictionary*)presetValue;
      RTC_LOG(LS_INFO) << "Found HighSpeed preset with " << [encoderSettings count] << " settings";
    } else {
      RTC_LOG(LS_WARNING) << "HighSpeed preset not found in available presets";
    }
  } else if (status == kVTPropertyNotSupportedErr) {
    RTC_LOG(LS_INFO) << "Preset dictionaries not supported on this OS version";
  } else {
    RTC_LOG(LS_WARNING) << "Failed to query preset dictionaries: " << status;
  }

  return encoderSettings;
}

- (int)resetCompressionSession {
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
  int64_t nv12type = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  CFNumberRef pixelFormat = CFNumberCreate(nullptr, kCFNumberLongType, &nv12type);
  CFTypeRef values[attributesSize] = {kCFBooleanTrue, ioSurfaceValue, pixelFormat};
  CFDictionaryRef sourceAttributes = CreateCFTypeDictionary(keys, values, attributesSize);
  if (ioSurfaceValue) {
    CFRelease(ioSurfaceValue);
    ioSurfaceValue = nullptr;
  }
  if (pixelFormat) {
    CFRelease(pixelFormat);
    pixelFormat = nullptr;
  }
  CFMutableDictionaryRef encoder_specs = CFDictionaryCreateMutable(
      nullptr, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

  if (@available(iOS 17.4, macCatalyst 17.4, macOS 10.9, tvOS 17.4, visionOS 1.1, *)) {
    CFDictionarySetValue(encoder_specs,
                         kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder,
                         kCFBooleanTrue);
  }

  // LowLatencyRateControl is available only in software encoder and enabling it causes
  // VideoToolbox to use the software encoder instead of the hardware encoder.
  //
  // if (@available(iOS 14.5, macCatalyst 14.5, macOS 11.3, tvOS 14.5, visionOS 1.0, *)) {
  //   CFDictionarySetValue(encoder_specs, kVTVideoEncoderSpecification_EnableLowLatencyRateControl,
  //                        kCFBooleanTrue);
  // }

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
  
  // Try to apply HighSpeed preset configuration for optimized low-latency encoding
  // The HighSpeed preset prioritizes encoding speed over quality, disables frame
  // reordering, and is ideal for real-time video conferencing scenarios.
  NSDictionary* presetSettings = [self getEncoderSettingsForPreset];
  
  if (presetSettings && [presetSettings count] > 0) {
    // Apply the preset settings dictionary to the compression session
    OSStatus status = VTSessionSetProperties(_compressionSession, 
                                             (__bridge CFDictionaryRef)presetSettings);
    if (status == noErr) {
      RTC_LOG(LS_INFO) << "Successfully applied HighSpeed preset settings";
    } else {
      RTC_LOG(LS_WARNING) << "VTSessionSetProperties failed with status: " << status;
    }
  }
  
  // Set HEVC Main profile (8-bit) for best compatibility and performance
  // Main profile is optimal for remote control/desktop streaming as it:
  // - Has universal hardware decoder support
  // - Is faster to encode/decode than Main10
  // - Sufficient for standard 8-bit RGB desktop content
  OSStatus status = VTSessionSetProperty(_compressionSession,
                                        kVTCompressionPropertyKey_ProfileLevel,
                                        kVTProfileLevel_HEVC_Main_AutoLevel);
  if (status != noErr) {
    RTC_LOG(LS_WARNING) << "VTSessionSetProperty(ProfileLevel) failed: " << status;
  }
  
  // Essential property: Indicate real-time compression session for low-latency conferencing
  status = VTSessionSetProperty(_compressionSession, 
                                kVTCompressionPropertyKey_RealTime, 
                                kCFBooleanTrue);
  if (status != noErr) {
    RTC_LOG(LS_WARNING) << "VTSessionSetProperty(RealTime) failed: " << status;
  }
  
  // Hint for rate control: Indicate expected frame rate (typically 30 fps for WebRTC)
  // When RealTime is true, the encoder may optimize energy usage based on this
  int32_t expectedFrameRate = 30;
  status = VTSessionSetProperty(_compressionSession,
                                kVTCompressionPropertyKey_ExpectedFrameRate,
                                (__bridge CFNumberRef)@(expectedFrameRate));
  if (status != noErr) {
    RTC_LOG(LS_WARNING) << "VTSessionSetProperty(ExpectedFrameRate) failed: " << status;
  }
  
  // Set maximum QP for screen sharing mode on supported OS versions.
  // https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_maxallowedframeqp
  if (@available(iOS 15.0, macOS 12.0, *)) {
    if (_mode == RTC_OBJC_TYPE(RTCVideoCodecModeScreensharing)) {
      RTC_LOG(LS_INFO) << "Configuring VideoToolbox to use maxQP: " << kHighh265QpThreshold
                       << " mode: " << _mode;
      SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_MaxAllowedFrameQP,
                           kHighh265QpThreshold);
    }
  }
  // Reduce the encoder's internal buffering for lower latency if available.
  // kVTCompressionPropertyKey_MaxFrameDelayCount is supported on macOS/iOS for HEVC.
  // SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_MaxFrameDelayCount, 1);
  [self setEncoderBitrateBps:_targetBitrateBps];

  // Set a relatively large value for keyframe emission (7200 frames or 4 minutes).
  SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, 7200);
  SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                       240);
  
  status = VTCompressionSessionPrepareToEncodeFrames(_compressionSession);
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

- (void)setBitrateBps:(uint32_t)bitrateBps {
  if (_encoderBitrateBps != bitrateBps) {
    [self setEncoderBitrateBps:bitrateBps];
  }
}

- (void)setEncoderBitrateBps:(uint32_t)bitrateBps {
  if (_compressionSession) {
    SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_AverageBitRate, bitrateBps);
    _encoderBitrateBps = bitrateBps;
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