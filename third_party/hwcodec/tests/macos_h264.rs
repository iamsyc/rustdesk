#![cfg(target_os = "macos")]

use hwcodec::{
    common::{Quality::Quality_Default, RateControl::RC_CBR},
    ffmpeg::{AVHWDeviceType, AVPixelFormat},
    ffmpeg_ram::{
        decode::{DecodeContext, Decoder},
        encode::{EncodeContext, Encoder},
    },
};

extern "C" {
    fn avcodec_version() -> u32;
}

#[test]
fn native_decode_matches_owned_planes() {
    use std::ffi::c_void;
    extern "C" {
        fn CVPixelBufferLockBaseAddress(buffer: *mut c_void, flags: u64) -> i32;
        fn CVPixelBufferUnlockBaseAddress(buffer: *mut c_void, flags: u64) -> i32;
        fn CVPixelBufferGetBaseAddressOfPlane(buffer: *mut c_void, plane: usize) -> *const u8;
        fn CVPixelBufferGetBytesPerRowOfPlane(buffer: *mut c_void, plane: usize) -> usize;
    }
    let samples: [(&str, &[u8]); 2] = [
        ("h264", include_bytes!("../src/res/720p.h264")),
        ("hevc", include_bytes!("../src/res/720p.h265")),
    ];
    for (codec, packet) in samples {
        let ctx = DecodeContext {
            name: codec.into(),
            device_type: AVHWDeviceType::AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
            thread_count: 1,
        };
        let mut owned = Decoder::new(ctx.clone()).expect("owned decoder");
        let mut native = Decoder::new(ctx).expect("native decoder");
        let mut retained = None;
        for _ in 0..8 {
            let expected = owned.decode(packet).expect("owned decode");
            assert_eq!(expected.len(), 1);
            let expected = &expected[0];
            let actual = native
                .decode_native(packet)
                .expect("native decode")
                .expect("frame");
            assert_eq!(
                (actual.width, actual.height),
                (expected.width, expected.height)
            );
            assert_eq!(expected.pixfmt, AVPixelFormat::AV_PIX_FMT_NV12);
            unsafe {
                assert_eq!(CVPixelBufferLockBaseAddress(actual.as_ptr(), 1), 0);
                for plane in 0..2 {
                    let data = CVPixelBufferGetBaseAddressOfPlane(actual.as_ptr(), plane);
                    let stride = CVPixelBufferGetBytesPerRowOfPlane(actual.as_ptr(), plane);
                    let rows = if plane == 0 {
                        actual.height
                    } else {
                        (actual.height + 1) / 2
                    };
                    for row in 0..rows as usize {
                        let offset = row * expected.linesize[plane] as usize;
                        assert_eq!(
                            std::slice::from_raw_parts(
                                data.add(row * stride),
                                actual.width as usize
                            ),
                            &expected.data[plane][offset..offset + actual.width as usize]
                        );
                    }
                }
                assert_eq!(CVPixelBufferUnlockBaseAddress(actual.as_ptr(), 1), 0);
            }
            if retained.is_none() {
                retained = Some(actual.clone());
            }
        }
        drop(native);
        let frame = retained.expect("retained frame");
        unsafe {
            assert_eq!(CVPixelBufferLockBaseAddress(frame.as_ptr(), 1), 0);
            assert!(!CVPixelBufferGetBaseAddressOfPlane(frame.as_ptr(), 0).is_null());
            assert_eq!(CVPixelBufferUnlockBaseAddress(frame.as_ptr(), 1), 0);
        }
        println!("PASS {codec}: native pixels match; retained frame outlives decoder");
    }
}

#[test]
fn h264_is_detected_and_pending_output_does_not_fail_encoding() {
    env_logger::init();
    let version = unsafe { avcodec_version() };
    println!(
        "Linked libavcodec {}.{}.{}",
        version >> 16,
        (version >> 8) & 255,
        version & 255
    );
    let mut ctx = EncodeContext {
        name: "h264_videotoolbox".into(),
        mc_name: None,
        width: 1920,
        height: 1200,
        pixfmt: AVPixelFormat::AV_PIX_FMT_NV12,
        align: 64,
        fps: 30,
        gop: i32::MAX,
        rc: RC_CBR,
        quality: Quality_Default,
        kbs: 4000,
        q: -1,
        thread_count: 1,
    };
    let detected = Encoder::available_encoders(ctx.clone(), None);
    assert!(detected.iter().any(|v| v.name == "h264_videotoolbox"));

    for width in [1920, 2880] {
        for fmt in [
            AVPixelFormat::AV_PIX_FMT_YUV420P,
            AVPixelFormat::AV_PIX_FMT_NV12,
        ] {
            ctx.width = width;
            ctx.height = width * 5 / 8;
            ctx.pixfmt = fmt;
            let mut encoder = Encoder::new(ctx.clone()).expect("create H264 hardware encoder");
            let mut decoder = Decoder::new(DecodeContext {
                name: "h264".into(),
                device_type: AVHWDeviceType::AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                thread_count: 1,
            })
            .expect("create H264 hardware decoder");
            let input = vec![128; encoder.length as usize];
            let mut packets = 0;
            let mut keyframes = 0;
            let mut decoded = 0;
            for i in 0..60 {
                let frames = encoder.encode(&input, i * 33).expect("accept valid input");
                for packet in frames.iter() {
                    for frame in decoder.decode(&packet.data).expect("decode H264 packet") {
                        assert_eq!((frame.width, frame.height), (ctx.width, ctx.height));
                        assert!(!frame.data.is_empty());
                        decoded += 1;
                    }
                }
                packets += frames.len();
                keyframes += frames.iter().filter(|frame| frame.key == 1).count();
            }
            assert!(
                packets > 0 && keyframes > 0 && decoded > 0,
                "encoder must produce a keyframe"
            );
            assert!(
                encoder.encode(&[], 2000).is_err(),
                "invalid input must fail"
            );
        }
    }
}
