// Pure contract checks: no renderer, filesystem, clock, audio device or GPU.
#include "Scene/SceneFrameExport.hpp"
#include <cstdlib>
#include <cmath>
#include <iostream>
#include <thread>

namespace {
void require(bool condition) {
    if (!condition) {
        std::cerr << "Scene frame export contract FAILED\n";
        std::abort();
    }
}
}

int main() {
    using namespace wallpaper;
    auto state = std::make_shared<SceneFrameExportState>();
    require(state->status() == -2);
    require(!state->enable(0));
    require(!state->enable(121));
    require(state->enable(60));
    require(!state->enable(30));
    require(state->status() == 0);
    require(!state->request(0, {}));
    state->ready();
    int completions = 0;
    auto first = state->request(0, [&](int status, auto, auto, auto, auto) {
        require(status == 0);
        ++completions;
    });
    require(first && first->time() == 0 && first->step() == 0);
    require(!state->request(0, {}));
    require(!state->request(1, {}));
    first->finish(0);
    first->finish(-1);
    require(completions == 1);
    require(!state->request(0, {}));
    require(!state->request(2, {}));
    for (uint32_t index = 1; index < 18'000; ++index) {
        auto frame = state->request(index, {});
        require(frame && frame->index == index && frame->fps == 60);
        require(std::abs(frame->time() - static_cast<double>(index) / 60) < 1e-12);
        require(std::abs(frame->step() - 1.0 / 60) < 1e-12);
        frame->finish(0);
    }
    require(!state->request(18'000, {}));
    auto cancelling = std::make_shared<SceneFrameExportState>();
    require(cancelling->enable(60));
    cancelling->ready();
    auto cancelled = cancelling->request(0, [&](int status, auto, auto, auto, auto) {
        require(status == -1);
        ++completions;
    });
    require(cancelled != nullptr);
    cancelling->fail();
    cancelled->finish(0);
    require(completions == 2 && cancelling->status() == -1);
    cancelling->ready();
    require(cancelling->status() == -1 && !cancelling->request(1, {}));
    auto race = std::make_shared<SceneFrameExportRequest>(0, 60,
        [&](int, auto, auto, auto, auto) { ++completions; });
    std::thread left([&] { race->finish(0); });
    std::thread right([&] { race->finish(-1); });
    left.join(); right.join();
    require(completions == 3);
    for (int trial = 0; trial < 100; ++trial) {
        auto racing = std::make_shared<SceneFrameExportState>();
        require(racing->enable(120));
        racing->ready();
        int calls = 0;
        auto request = racing->request(0, [&](int code, auto, auto, auto, auto) {
            require(code == 0 || code == -1);
            ++calls;
        });
        std::thread success([&] { request->finish(0); });
        std::thread failure([&] { racing->fail(); });
        success.join(); failure.join();
        require(calls == 1 && racing->status() == -1 && !racing->request(1, {}));
    }
    std::cout << "Scene frame export contract: 18000 sequential frames, admission/cancel/exactly-once PASS\n";
}
