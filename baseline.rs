//! Opt-in, snapshot-only backend for comparing the existing production React UI.
//! Compiled only with native-prototype-benchmark; never writes an index.
use crate::{
    background::{BackgroundLoopChannels, emit_status_bar_update, handle_icon_viewport_update},
    lifecycle::{APP_QUIT, AppLifecycleState, update_app_state},
};
use search_cache::{SearchCache, read_cache_from_file};
use std::{path::Path, time::Instant};
use tauri::Emitter;

pub(crate) fn run(app: &tauri::AppHandle, channels: BackgroundLoopChannels) {
    let path = std::env::var("EVERYTHING_MAC_BENCHMARK_INDEX")
        .expect("benchmark build requires EVERYTHING_MAC_BENCHMARK_INDEX; it never scans");
    let started = Instant::now();
    let storage = read_cache_from_file(Path::new(&path)).expect("Cannot read benchmark snapshot");
    let mut cache = SearchCache::from_persistent_storage(storage, &APP_QUIT);
    println!(
        "BENCHMARK_LOAD_MS {}",
        started.elapsed().as_secs_f64() * 1000.0
    );
    emit_status_bar_update(app, cache.get_total_files(), 0, 0);
    update_app_state(app, AppLifecycleState::Ready);
    loop {
        crossbeam_channel::select! {
            recv(channels.finish_rx) -> tx => {
                if let Ok(tx) = tx { let _ = tx.send(None); }
                return;
            }
            recv(channels.search_rx) -> job => {
                let Ok(job) = job else { return };
                let started = Instant::now();
                let result = cache.search_query_with_options(job.query, job.options.into(), job.cancellation_token);
                let _ = app.emit("native_benchmark_backend", started.elapsed().as_secs_f64() * 1000.0);
                let _ = job.result_tx.send(result);
            }
            recv(channels.node_info_rx) -> job => {
                let Ok(job) = job else { return };
                let _ = job.response_tx.send(cache.expand_file_nodes(&job.slab_indices));
            }
            recv(channels.icon_viewport_rx) -> update => {
                if let Ok(update) = update { handle_icon_viewport_update(&mut cache, update, &channels.icon_update_tx); }
            }
            recv(channels.update_window_state_rx) -> _ => {}
            recv(channels.watch_config_rx) -> _ => {}
            recv(channels.rescan_rx) -> _ => {}
        }
    }
}
