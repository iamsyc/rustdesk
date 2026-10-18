//
//  TextureRgbaApi.m
//  texture_rgba_renderer
//
//  Created by kingtous on 2023/2/19.
//

#import <Foundation/Foundation.h>
#import "texture_rgba_renderer/texture_rgba_renderer-Swift.h"

#if __cplusplus
extern "C" {
#endif
    
/// Keep the same name with Windows.
void FlutterRgbaRendererPluginOnRgba(void* texture_rgba_ptr, const uint8_t* buffer, int len, int width, int height, int stride_align) {
    TextRgba* texture_rgba = (__bridge TextRgba *)(texture_rgba_ptr);
    [texture_rgba markFrameAvaliableRawWithBuffer:buffer len:len width:width height:height stride_align: stride_align];
}

typedef void (*PixelBufferCompletion)(int display, uint64_t gpu_us, bool published, bool success);
int FlutterRgbaRendererPluginOnPixelBuffer(void* texture_rgba_ptr, void* pixel_buffer,
                                         int display, PixelBufferCompletion completion) {
    TextRgba* texture_rgba = (__bridge TextRgba *)(texture_rgba_ptr);
    return [texture_rgba markPixelBufferAvailable:(CVPixelBufferRef)pixel_buffer
        completion:^(uint64_t elapsed, BOOL published, BOOL success) { completion(display, elapsed, published, success); }];
}

#if __cplusplus
} //Extern C
#endif
