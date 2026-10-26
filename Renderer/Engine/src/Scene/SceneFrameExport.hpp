#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <span>
#include <utility>

namespace wallpaper {

/// One immutable output tick. Completion is exactly once even if a GPU callback
/// races cancellation; the pixel span is valid only during that callback.
struct SceneFrameExportRequest {
    using Completion = std::function<void(int, std::span<const uint8_t>, uint32_t, uint32_t, bool)>;
    const uint32_t index;
    const uint32_t fps;
    Completion completion;
    std::atomic<bool> completed { false };

    SceneFrameExportRequest(uint32_t frame, uint32_t rate, Completion callback)
        : index(frame), fps(rate), completion(std::move(callback)) {}
    void finish(int status, std::span<const uint8_t> pixels = {}, uint32_t width = 0,
                uint32_t height = 0, bool bgra = true) {
        if (completed.exchange(true, std::memory_order_acq_rel)) return;
        // Only the exchange winner touches completion. std::function's move is
        // noexcept, and keeps the callback alive if it releases this request.
        auto callback = std::move(completion);
        if (callback) {
            try { callback(status, pixels, width, height, bgra); }
            catch (...) {} // No exception may escape a Metal completion callback.
        }
    }
    double time() const { return static_cast<double>(index) / fps; }
    double step() const { return index == 0 ? 0.0 : 1.0 / fps; }
};

/// Cross-thread admission/terminal state, independent of clocks and GPU APIs.
/// A failed/cancelled tick is terminal: retry requires a fresh isolated handle.
class SceneFrameExportState : public std::enable_shared_from_this<SceneFrameExportState> {
public:
    bool enable(uint32_t fps) {
        std::lock_guard lock(mutex_);
        if (status_ != -2 || fps < 1 || fps > 120) return false;
        fps_ = fps;
        status_ = 0;
        return true;
    }
    bool enabled() const { std::lock_guard lock(mutex_); return fps_ != 0; }
    uint32_t fps() const { std::lock_guard lock(mutex_); return fps_; }
    int status() const { std::lock_guard lock(mutex_); return status_; }
    void ready() { std::lock_guard lock(mutex_); if (status_ == 0) status_ = 1; }
    std::shared_ptr<SceneFrameExportRequest> request(uint32_t index,
                                                   SceneFrameExportRequest::Completion completion) {
        std::lock_guard lock(mutex_);
        if (status_ != 1 || pending_ || index != next_ || index >= 18'000) return {};
        auto weak = weak_from_this();
        auto callback = [weak, index, completion = std::move(completion)](
                            int result, std::span<const uint8_t> pixels,
                            uint32_t width, uint32_t height, bool bgra) {
            if (auto alive = weak.lock()) {
                std::lock_guard guard(alive->mutex_);
                alive->pending_.reset();
                if (result == 0 && alive->status_ == 1 && alive->next_ == index) ++alive->next_;
                else { alive->status_ = -1; result = -1; }
            } else {
                result = -1;
            }
            if (completion) completion(result, result == 0 ? pixels : std::span<const uint8_t> {},
                                       result == 0 ? width : 0, result == 0 ? height : 0, bgra);
        };
        pending_ = std::make_shared<SceneFrameExportRequest>(index, fps_, std::move(callback));
        return pending_;
    }
    void fail() {
        std::shared_ptr<SceneFrameExportRequest> pending;
        {
            std::lock_guard lock(mutex_);
            if (fps_ == 0) return;
            status_ = -1;
            pending = pending_;
        }
        if (pending) pending->finish(-1);
    }
private:
    mutable std::mutex mutex_;
    int status_ { -2 };
    uint32_t fps_ { 0 };
    uint32_t next_ { 0 };
    std::shared_ptr<SceneFrameExportRequest> pending_;
};

} // namespace wallpaper
