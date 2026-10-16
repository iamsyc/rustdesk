#![cfg(target_os = "macos")]

use hwcodec::{
    common::{Quality::Quality_Default, RateControl::RC_CBR},
    ffmpeg::AVPixelFormat,
    ffmpeg_ram::encode::{EncodeContext, Encoder},
};

#[test]
fn h264_is_detected_and_pending_output_does_not_fail_encoding() {
    env_logger::init();
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
            let input = vec![128; encoder.length as usize];
            let mut packets = 0;
            let mut keyframes = 0;
            for i in 0..60 {
                let frames = encoder.encode(&input, i * 33).expect("accept valid input");
                packets += frames.len();
                keyframes += frames.iter().filter(|frame| frame.key == 1).count();
            }
            assert!(
                packets > 0 && keyframes > 0,
                "encoder must produce a keyframe"
            );
            assert!(
                encoder.encode(&[], 2000).is_err(),
                "invalid input must fail"
            );
        }
    }
}
