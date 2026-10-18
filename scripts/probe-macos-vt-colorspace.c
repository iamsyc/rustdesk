#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static int equivalent(CGColorSpaceRef actual, CGColorSpaceRef expected) {
    const CGFloat samples[][4] = {{.8,.8,.8,1}, {.2,.4,.6,1}, {.8,.1,.3,1},
                                  {.1,.7,.2,1}, {.1,.2,.9,1}};
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    int valid = actual && expected;
    for (unsigned i = 0; valid && i < sizeof(samples)/sizeof(samples[0]); i++) {
        CGColorRef a = CGColorCreate(actual, samples[i]);
        CGColorRef b = CGColorCreate(expected, samples[i]);
        CGColorRef x = CGColorCreateCopyByMatchingToColorSpace(srgb, kCGRenderingIntentDefault, a, NULL);
        CGColorRef y = CGColorCreateCopyByMatchingToColorSpace(srgb, kCGRenderingIntentDefault, b, NULL);
        valid = x && y;
        for (int c = 0; valid && c < 3; c++)
            valid = fabs(CGColorGetComponents(x)[c] - CGColorGetComponents(y)[c]) < 1e-5;
        if (x) CGColorRelease(x);
        if (y) CGColorRelease(y);
        CGColorRelease(a);
        CGColorRelease(b);
    }
    CGColorSpaceRelease(srgb);
    return valid;
}

int main(int argc, char **argv) {
    int require_reuse = argc == 2 && !strcmp(argv[1], "--require-reuse");
    AVBufferRef *device = NULL, *frames = NULL;
    AVFrame *frame = av_frame_alloc();
    CVPixelBufferRef buffers[2] = {NULL, NULL};
    CGColorSpaceRef first = NULL;
    int reused = 0, checks = 0;
    CFMutableDataRef mutable_icc = NULL;
    if (av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) < 0)
        return 2;
    frames = av_hwframe_ctx_alloc(device);
    if (!frames || !frame) return 2;
    AVHWFramesContext *context = (AVHWFramesContext *)frames->data;
    context->format = AV_PIX_FMT_VIDEOTOOLBOX;
    context->sw_format = AV_PIX_FMT_NV12;
    context->width = context->height = 16;
    if (av_hwframe_ctx_init(frames) < 0) return 2;
    frame->format = AV_PIX_FMT_VIDEOTOOLBOX;
    frame->hw_frames_ctx = av_buffer_ref(frames);
    for (int i = 0; i < 2; i++)
        if (CVPixelBufferCreate(NULL, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                               NULL, &buffers[i]) != kCVReturnSuccess) return 2;
    const enum AVColorPrimaries primaries[] = {AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE170M,
        AVCOL_PRI_BT709, AVCOL_PRI_BT709, AVCOL_PRI_BT709, AVCOL_PRI_BT709,
        AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE170M};
    const enum AVColorTransferCharacteristic transfers[] = {AVCOL_TRC_BT709, AVCOL_TRC_BT709,
        AVCOL_TRC_BT709, AVCOL_TRC_GAMMA22, AVCOL_TRC_GAMMA28, AVCOL_TRC_BT709,
        AVCOL_TRC_BT709, AVCOL_TRC_BT709, AVCOL_TRC_BT709, AVCOL_TRC_BT709};
    for (int i = 0; i < 10; i++) {
        CVPixelBufferRef buffer = buffers[i % 2];
        frame->color_primaries = primaries[i];
        frame->color_trc = transfers[i];
        frame->colorspace = i == 2 ? AVCOL_SPC_BT709 : AVCOL_SPC_SMPTE170M;
        if (i >= 6) {
            CGColorSpaceRef icc = CGColorSpaceCreateWithName(i % 2 == 0 ? kCGColorSpaceDisplayP3 : kCGColorSpaceSRGB);
            CFDataRef bytes = CGColorSpaceCopyICCData(icc);
            if (i == 8)
                mutable_icc = CFDataCreateMutableCopy(NULL, 0, bytes);
            if (i == 9)
                CFDataReplaceBytes(mutable_icc, CFRangeMake(0, CFDataGetLength(mutable_icc)),
                                   CFDataGetBytePtr(bytes), CFDataGetLength(bytes));
            CVBufferSetAttachment(buffer, kCVImageBufferICCProfileKey,
                i >= 8 ? mutable_icc : bytes, kCVAttachmentMode_ShouldPropagate);
            CFRelease(bytes);
            CGColorSpaceRelease(icc);
        }
        if (av_vt_pixbuf_set_attachments(NULL, buffer, frame) < 0) return 2;
        CGColorSpaceRef actual = (CGColorSpaceRef)CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, NULL);
        CFDictionaryRef properties = CVBufferCopyAttachments(buffer, kCVAttachmentMode_ShouldPropagate);
        CGColorSpaceRef expected = CVImageBufferCreateColorSpaceFromAttachments(properties);
        if (!equivalent(actual, expected)) {
            fprintf(stderr, "FAIL: color metadata case %d produced different colors\n", i);
            return 1;
        }
        if (i == 0) first = CGColorSpaceRetain(actual);
        if (i == 1) reused = first == actual;
        CGColorSpaceRelease(actual);
        CGColorSpaceRelease(expected);
        CFRelease(properties);
        checks++;
    }
    if (mutable_icc) CFRelease(mutable_icc);
    CGColorSpaceRelease(first);
    for (int i = 0; i < 2; i++) CVPixelBufferRelease(buffers[i]);
    av_frame_free(&frame);
    av_buffer_unref(&frames);
    av_buffer_unref(&device);
    printf("{\"color_cases\":%d,\"same_description_reused\":%s}\n", checks, reused ? "true" : "false");
    return require_reuse && !reused ? 1 : 0;
}
