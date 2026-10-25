// What a scene does when the native Metal backend cannot draw it. There is no
// other backend to try: the scene is held and reported.
//
// Driven end to end through `SceneWallpaper` on a `CAMetalLayer` no window owns,
// so no desktop is involved. The failures are forced where a real one would
// strike (`SceneBackendFaults`): the admission gate, creating the native
// renderer, compiling its graph, a frame after the scene runs, and taking a
// replacement surface. The evidence is what is observable from outside: the
// failure was logged once, the frame loop stopped without presenting again, and
// the surface shows its last frame (a layer that drew) or the project's preview
// picture (a layer that did not).

#include "Core/RendererCounters.hpp"
#include "Scene/SceneBackendFaults.hpp"
#include "Scene/SceneBackendSelection.hpp"
#include "Scene/SceneWallpaper.hpp"
#include "Scene/SceneWallpaperSurface.hpp"
#include "Utils/Logging.h"
#include "Platform/Apple/SceneWallpaperBindings.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

using namespace wallpaper;
using namespace std::chrono_literals;
using wallpaper::testing::SceneBackendFault;
using wallpaper::testing::SceneBackendFaults;

namespace
{

// A 1x1 PNG, the project's preview picture.
constexpr const char* kPreviewPngBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

void WriteText(const std::filesystem::path& path, const std::string& text)
{
    std::filesystem::create_directories(path.parent_path());
    std::ofstream(path) << text;
}

void WritePreview(const std::filesystem::path& project_directory)
{
    NSData* png = [[NSData alloc] initWithBase64EncodedString:@(kPreviewPngBase64) options:0];
    std::filesystem::create_directories(project_directory);
    std::ofstream out(project_directory / "preview.png", std::ios::binary);
    out.write(static_cast<const char*>(png.bytes), static_cast<std::streamsize>(png.length));
}

/// One opaque card drawn through its own shaders, with a preview picture beside
/// the project file unless `with_preview` is off.
std::filesystem::path WriteScene(const std::filesystem::path& root, bool with_preview = true)
{
    WriteText(root / "project.json",
              R"({"title":"Card","type":"scene","file":"layout.json","general":{"properties":{}}})");
    if (with_preview) WritePreview(root);
    WriteText(root / "models/card.json",
              R"({"width":160,"height":96,"material":"materials/card.json"})");
    WriteText(root / "materials/card.json",
              R"({"passes":[{"shader":"card","blending":"translucent","cullmode":"nocull",)"
              R"("depthtest":"disabled","depthwrite":"disabled"}]})");
    WriteText(root / "shaders/card.vert",
              "uniform mat4 g_ModelViewProjectionMatrix;\n"
              "attribute vec3 a_Position;\n"
              "attribute vec2 a_TexCoord;\n"
              "varying vec2 v_TexCoord;\n"
              "void main() {\n"
              "gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
              "v_TexCoord = a_TexCoord;\n"
              "}\n");
    WriteText(root / "shaders/card.frag",
              "varying vec2 v_TexCoord;\n"
              "void main() {\n"
              "gl_FragColor = vec4(v_TexCoord, 0.4, 1.0);\n"
              "}\n");
    WriteText(root / "layout.json",
              R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
              R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],)"
              R"("clearcolor":[0.1,0.2,0.3],"cameraparallax":false,)"
              R"("orthogonalprojection":{"width":384,"height":256}},)"
              R"("objects":[{"id":1,"name":"card","image":"models/card.json",)"
              R"("origin":[192,128,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}]})");
    return root / "project.json";
}

// A wholly self-authored empty package: the scene exists only inside PKGV0001,
// not as a loose JSON file, and needs no shared shader or texture resources.
std::filesystem::path WriteEmptyPackedScene(const std::filesystem::path& root)
{
    WriteText(root / "project.json",
              R"({"type":"scene","file":"scene.json","general":{"properties":{}}})");
    const std::string scene =
            R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
            R"("general":{"clearcolor":"0 0 0","cameraparallax":false,)"
            R"("orthogonalprojection":{"width":64,"height":64}},"objects":[]})";
    std::ofstream pkg(root / "scene.pkg", std::ios::binary);
    const auto integer = [&](uint32_t value) {
        for (int shift = 0; shift < 32; shift += 8)
            pkg.put(static_cast<char>((value >> shift) & 255));
    };
    const auto text = [&](const std::string& value) {
        integer(static_cast<uint32_t>(value.size()));
        pkg.write(value.data(), static_cast<std::streamsize>(value.size()));
    };
    text("PKGV0001");
    integer(1);
    text("scene.json");
    integer(0);
    integer(static_cast<uint32_t>(scene.size()));
    pkg.write(scene.data(), static_cast<std::streamsize>(scene.size()));
    return root / "project.json";
}

/// `WriteScene`'s card under one effect whose fragment shader is `effect_body`
/// (the statements of `main`, which may use `c`, the layer's colour). The effect
/// chain's closing passthrough is the plain copy Wallpaper Engine's is.
std::filesystem::path WriteSceneWithEffect(const std::filesystem::path& root,
                                           const std::string& effect_body)
{
    const auto project = WriteScene(root);
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec3 a_Position;\n"
        "attribute vec2 a_TexCoord;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
        "v_TexCoord = a_TexCoord;\n"
        "}\n";
    const auto pass = [&](const std::string& shader) {
        return R"({"passes":[{"shader":")" + shader + R"(","blending":"normal","cullmode":"nocull",)"
               R"("depthtest":"disabled","depthwrite":"disabled","textures":[null]}]})";
    };
    WriteText(root / "shaders/effects/tint.vert", vertex);
    WriteText(root / "shaders/effects/tint.frag",
              "uniform sampler2D g_Texture0;\n"
              "varying vec2 v_TexCoord;\n"
              "void main() {\n"
              "vec4 c = texture2D(g_Texture0, v_TexCoord);\n" + effect_body + "\n"
              "}\n");
    WriteText(root / "materials/effects/tint.json", pass("effects/tint"));
    WriteText(root / "effects/tint/effect.json",
              R"({"name":"tint","passes":[{"material":"materials/effects/tint.json"}]})");
    WriteText(root / "shaders/through.vert", vertex);
    WriteText(root / "shaders/through.frag",
              "uniform sampler2D g_Texture0;\n"
              "varying vec2 v_TexCoord;\n"
              "void main() {\n"
              "gl_FragColor = texture2D(g_Texture0, v_TexCoord);\n"
              "}\n");
    WriteText(root / "materials/util/effectpassthrough.json", pass("through"));
    WriteText(root / "layout.json",
              R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
              R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],)"
              R"("clearcolor":[0.1,0.2,0.3],"cameraparallax":false,)"
              R"("orthogonalprojection":{"width":384,"height":256}},)"
              R"("objects":[{"id":1,"name":"card","image":"models/card.json",)"
              R"("origin":[192,128,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,)"
              R"("effects":[{"file":"effects/tint/effect.json","id":2,"visible":true}]}]})");
    return project;
}

/// Lines of the engine's own log, kept while a test runs.
class LogCapture {
public:
    LogCapture()
    {
        Lines().clear();
        SetWallpaperLogCallback(&Sink);
    }
    ~LogCapture() { SetWallpaperLogCallback(nullptr); }

    static int Count(const std::string& needle)
    {
        std::scoped_lock lock(Mutex());
        int              count = 0;
        for (const auto& line : Lines()) {
            if (line.find(needle) != std::string::npos) ++count;
        }
        return count;
    }

private:
    static std::mutex& Mutex()
    {
        static std::mutex mutex;
        return mutex;
    }
    static std::vector<std::string>& Lines()
    {
        static std::vector<std::string> lines;
        return lines;
    }
    static void Sink(int, const char*, int, const char* message)
    {
        std::scoped_lock lock(Mutex());
        Lines().emplace_back(message);
    }
};

constexpr const char* kFailureLine = "scene cannot be drawn with native Metal";

/// A running wallpaper on a layer no window owns.
class Running {
public:
    Running(const std::filesystem::path& project, const std::filesystem::path& scratch)
    {
        m_layer               = [CAMetalLayer layer];
        m_layer.device        = MTLCreateSystemDefaultDevice();
        m_layer.pixelFormat   = MTLPixelFormatBGRA8Unorm;
        m_layer.contentsScale = 1.0;
        m_layer.frame         = CGRectMake(0, 0, kWidth, kHeight);
        m_layer.drawableSize  = CGSizeMake(kWidth, kHeight);

        SceneWallpaperInputTestAccess::UseNullSoundOutput(m_wallpaper);
        EXPECT_TRUE(m_wallpaper.init());
        m_wallpaper.setPropertyObject(PROPERTY_FIRST_FRAME_CALLBACK,
                                      std::make_shared<FirstFrameCallback>([this] {
                                          std::scoped_lock lock(m_mutex);
                                          ++m_first_frames;
                                          m_changed.notify_all();
                                      }));
        m_wallpaper.setPropertyObject(PROPERTY_RENDER_FAILURE_CALLBACK,
                                      std::make_shared<RenderFailureCallback>([this] {
                                          std::scoped_lock lock(m_mutex);
                                          ++m_failure_reports;
                                          m_changed.notify_all();
                                      }));
        m_wallpaper.initSurface(MakeSurface());

        std::filesystem::create_directories(scratch / "assets");
        SceneWallpaperConfig config;
        config.source     = project.string();
        config.assets     = (scratch / "assets").string();
        config.cache_path = (scratch / "cache").string();
        config.fps        = 60;
        config.paused     = false;
        m_wallpaper.applyConfig(config);
    }

    ~Running() { m_wallpaper.shutdown(); }

    /// The picture the host waits for: a presented frame, or a held failure.
    bool WaitForFirstFrame()
    {
        std::unique_lock lock(m_mutex);
        return m_changed.wait_for(lock, 30s, [&] { return m_first_frames > 0; });
    }
    bool WaitForFailureReports(int count)
    {
        std::unique_lock lock(m_mutex);
        return m_changed.wait_for(lock, 10s, [&] { return m_failure_reports >= count; });
    }
    int FirstFrames()
    {
        std::scoped_lock lock(m_mutex);
        return m_first_frames;
    }
    int FailureReports()
    {
        std::scoped_lock lock(m_mutex);
        return m_failure_reports;
    }

    SceneWallpaper& wallpaper() { return m_wallpaper; }
    CAMetalLayer*   layer() { return m_layer; }

    /// The host switching this surface to another wallpaper: the same
    /// wallpaper object takes a new source.
    void Reload(const std::filesystem::path& project, const std::filesystem::path& scratch)
    {
        SceneWallpaperConfig config;
        config.source     = project.string();
        config.assets     = (scratch / "assets").string();
        config.cache_path = (scratch / "cache").string();
        config.fps        = 60;
        config.paused     = false;
        m_wallpaper.applyConfig(config);
    }

    /// The host's rebuild of a surface at a new size; true when it succeeded.
    bool Resize(uint16_t width, uint16_t height)
    {
        if (! m_wallpaper.beginSurfaceReconfigure()) return false;
        m_layer.frame        = CGRectMake(0, 0, width, height);
        m_layer.drawableSize = CGSizeMake(width, height);
        return m_wallpaper.finishSurfaceReconfigure(MakeSurface(width, height));
    }

    /// The two halves of that rebuild, for a host that does work between them.
    bool Release() { return m_wallpaper.beginSurfaceReconfigure(); }
    bool Restore() { return m_wallpaper.finishSurfaceReconfigure(MakeSurface()); }

    uint64_t Presented() { return m_wallpaper.surfaceHealth().frames_presented; }
    uint64_t Completed() { return m_wallpaper.surfaceHealth().frames_completed; }

private:
    static constexpr uint16_t kWidth  = 1280;
    static constexpr uint16_t kHeight = 720;

    RenderInitInfo MakeSurface(uint16_t width = kWidth, uint16_t height = kHeight)
    {
        RenderInitInfo info;
        info.metal_layer      = (__bridge void*)m_layer;
        info.width            = width;
        info.height           = height;
        info.render_width     = width;
        info.render_height    = height;
        return info;
    }

    CAMetalLayer*           m_layer { nil };
    SceneWallpaper          m_wallpaper;
    std::mutex              m_mutex;
    std::condition_variable m_changed;
    int                     m_first_frames { 0 };
    int                     m_failure_reports { 0 };
};

class SceneFailurePolicy : public ::testing::Test {
protected:
    void SetUp() override
    {
        if (MTLCreateSystemDefaultDevice() == nil) {
            GTEST_SKIP() << "no Metal device on this machine; no surface could be created";
        }
        static int serial = 0;
        root_             = std::filesystem::temp_directory_path() /
                ("owe-failure-policy-" + std::to_string(::getpid()) + "-" + std::to_string(serial++));
        std::filesystem::remove_all(root_);
        std::filesystem::create_directories(root_);
        SceneBackendFaults::Instance().Reset();
        RendererCounters::SetEnabled(true);
    }

    void TearDown() override
    {
        SceneBackendFaults::Instance().Reset();
        RendererCounters::SetEnabled(false);
        std::error_code ignored;
        std::filesystem::remove_all(root_, ignored);
    }

    /// What every refusal must leave behind, however it was forced: the scene
    /// is held, not running anywhere, and reported once.
    void ExpectHeld(Running& running, SceneFailureStage stage, const std::string& reason)
    {
        const auto selection = running.wallpaper().sceneBackendSelection();
        EXPECT_TRUE(selection.failed());
        EXPECT_EQ(selection.failure_stage, stage) << ToString(selection.failure_stage);
        EXPECT_NE(selection.failure_reason.find(reason), std::string::npos)
            << selection.failure_reason;
        EXPECT_TRUE(selection.created);
        EXPECT_EQ(LogCapture::Count(kFailureLine), 1) << "the failure is said once";
        EXPECT_NE(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::Running);
    }

    std::filesystem::path root_;
};

// Loader failures happen before backend admission, so these tests deliberately use
// no Metal device. A nil native layer is a real surface description; loading must
// publish its own failure without reaching renderer creation or the preview path.
class SceneLoadFailurePolicy : public ::testing::Test {
protected:
    void SetUp() override
    {
        static int serial = 0;
        root_ = std::filesystem::temp_directory_path() /
                ("owe-load-failure-" + std::to_string(::getpid()) + "-" + std::to_string(serial++));
        ASSERT_FALSE(std::filesystem::exists(root_));
        std::filesystem::create_directories(root_);
        SceneBackendFaults::Instance().Reset();
        SceneWallpaperInputTestAccess::UseNullSoundOutput(wallpaper_);
        ASSERT_TRUE(wallpaper_.init());
        wallpaper_.setPropertyObject(PROPERTY_FIRST_FRAME_CALLBACK,
                std::make_shared<FirstFrameCallback>([this] { ++first_frames_; }));
        RenderInitInfo info;
        info.offscreen = true;
        wallpaper_.initSurface(info);
    }
    void TearDown() override
    {
        wallpaper_.shutdown();
        SceneBackendFaults::Instance().Reset();
        std::error_code ignored;
        std::filesystem::remove_all(root_, ignored);
    }
    SceneWallpaperConfig Config()
    {
        SceneWallpaperConfig config;
        config.source = WriteScene(root_ / "scene", false).string();
        config.assets = (root_ / "shared").string();
        config.cache_path = (root_ / "cache").string();
        config.muted = true;
        return config;
    }
    bool WaitForFailure(SceneFailureStage stage, const std::string& reason)
    {
        const auto deadline = std::chrono::steady_clock::now() + 5s;
        do {
            const auto selection = wallpaper_.sceneBackendSelection();
            if (selection.failure_stage == stage && selection.failure_reason == reason &&
                wallpaper_.surfaceHealth().stop_reason == SurfaceStopReason::GraphFailed) return true;
            std::this_thread::sleep_for(5ms);
        } while (std::chrono::steady_clock::now() < deadline);
        return false;
    }
    void ExpectNoFrame()
    {
        const auto health = wallpaper_.surfaceHealth();
        EXPECT_EQ(health.frames_completed, 0u);
        EXPECT_EQ(health.frames_presented, 0u);
        EXPECT_EQ(health.failed_frames, 0u);
        EXPECT_EQ(health.stop_reason, SurfaceStopReason::GraphFailed);
        EXPECT_EQ(first_frames_.load(), 0);
    }
    SceneWallpaper wallpaper_;
    std::filesystem::path root_;
    std::atomic<int> first_frames_ { 0 };
};

TEST_F(SceneLoadFailurePolicy, MissingSharedAssetsPublishesPrepareFailureWithoutInventingAFrame)
{
    LogCapture log;
    auto config = Config();
    config.source = WriteEmptyPackedScene(root_ / "packed").string();
    ASSERT_FALSE(std::filesystem::exists(root_ / "packed/scene.json"));
    wallpaper_.applyConfig(config);
    ASSERT_TRUE(WaitForFailure(SceneFailureStage::Prepare, "the shared assets folder could not be mounted"));
    ExpectNoFrame();
    EXPECT_EQ(LogCapture::Count(kFailureLine), 1);
    char reason[128] {};
    EXPECT_EQ(owe_scene_wallpaper_backend_failure(&wallpaper_), OWE_SCENE_FAILURE_PREPARE);
    EXPECT_EQ(owe_scene_wallpaper_backend_failure_reason(&wallpaper_, reason, sizeof(reason)),
              std::string("the shared assets folder could not be mounted").size());
    EXPECT_STREQ(reason, "the shared assets folder could not be mounted");
    owe_surface_health native_health {};
    ASSERT_EQ(owe_scene_wallpaper_surface_health(&wallpaper_, &native_health), 0);
    EXPECT_EQ(native_health.frames_presented, 0u);

    // A surface rebuild is not a successful load: it must not clear this reason
    // or call the first-frame callback for a scene that never reached parsing.
    ASSERT_TRUE(wallpaper_.beginSurfaceReconfigure());
    RenderInitInfo replacement;
    replacement.offscreen = true;
    EXPECT_TRUE(wallpaper_.finishSurfaceReconfigure(replacement));
    EXPECT_EQ(wallpaper_.sceneBackendSelection().failure_reason,
              "the shared assets folder could not be mounted");
    ExpectNoFrame();

    // The valid subsequent load really crosses admission. Refuse it there to
    // prove recovery without asking this CPU test to create any Metal device.
    std::filesystem::create_directories(config.assets);
    config.force_shader_refresh = true;
    SceneBackendFaults::Instance().Arm(SceneBackendFault::Admission, "new admission reached");
    wallpaper_.applyConfig(config);
    ASSERT_TRUE(WaitForFailure(SceneFailureStage::Unsupported, "new admission reached"));
    EXPECT_EQ(wallpaper_.surfaceHealth().frames_presented, 0u);
}

TEST_F(SceneLoadFailurePolicy, AMissingProjectDirectoryPublishesItsMountFailure)
{
    std::filesystem::create_directories(root_ / "shared");
    SceneWallpaperConfig config;
    config.source = (root_ / "missing/scene.json").string();
    config.assets = (root_ / "shared").string();
    config.muted = true;
    wallpaper_.applyConfig(config);
    ASSERT_TRUE(WaitForFailure(SceneFailureStage::Prepare, "the wallpaper files could not be mounted"));
    ExpectNoFrame();
}

TEST_F(SceneLoadFailurePolicy, EveryPreAdmissionFailureHasASpecificReasonAndNoFirstFrame)
{
    std::filesystem::create_directories(root_ / "shared");
    struct Case { const char* reason; const char* project; const char* scene; const char* saved; };
    const Case cases[] = {
        { "the wallpaper source could not be resolved", "not json", "{}", nullptr },
        { "the project is not a scene", R"({"type":"video","file":"movie.mp4"})", "{}", nullptr },
        { "the project properties could not be read", R"({"type":"scene","file":"scene.json"})", "{}", nullptr },
        { "the scene file is missing or empty", R"({"type":"scene","file":"scene.json","general":{"properties":{}}})", "", nullptr },
        { "the scene document could not be parsed", R"({"type":"scene","file":"scene.json","general":{"properties":{}}})", "{}", nullptr },
        { "the saved project properties could not be read", R"({"type":"scene","file":"scene.json","general":{"properties":{}}})", R"({"objects":[]})", "not json" },
    };
    for (std::size_t i = 0; i < std::size(cases); ++i) {
        SCOPED_TRACE(cases[i].reason);
        const auto folder = root_ / ("invalid-" + std::to_string(i));
        WriteText(folder / "project.json", cases[i].project);
        WriteText(folder / "scene.json", cases[i].scene);
        SceneWallpaperConfig config;
        config.source = (folder / "project.json").string();
        config.assets = (root_ / "shared").string();
        config.muted = true;
        config.has_project_property_override = cases[i].saved != nullptr;
        if (cases[i].saved != nullptr) config.project_property_override_json = cases[i].saved;
        wallpaper_.applyConfig(config);
        ASSERT_TRUE(WaitForFailure(SceneFailureStage::Prepare, cases[i].reason));
        ExpectNoFrame();
    }
}

} // namespace

// A scene the gate refuses is not drawn by anything else. The host is still told
// a first picture exists (otherwise its activation waits out 90 seconds and puts
// the previous wallpaper back), and that picture is the project's own preview.
TEST_F(SceneFailurePolicy, ARefusedAdmissionIsHeldWithThePreview)
{
    LogCapture log;
    SceneBackendFaults::Instance().Arm(SceneBackendFault::Admission, "forced refusal for the test");

    Running running(WriteScene(root_ / "scene"), root_ / "run");
    ASSERT_TRUE(running.WaitForFirstFrame()) << "the host would have waited for ever";
    std::this_thread::sleep_for(500ms);

    ExpectHeld(running, SceneFailureStage::Unsupported, "forced refusal for the test");
    EXPECT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::GraphFailed);
    EXPECT_EQ(running.Presented(), 0u) << "nothing was drawn, so nothing was presented";
    EXPECT_EQ(running.Completed(), 0u) << "the stopped clock kept running";
    EXPECT_EQ(running.FirstFrames(), 1) << "the host is told once";
    // No black frame: the layer carries the project's preview picture.
    ASSERT_EQ(running.layer().sublayers.count, 1u);
    EXPECT_NE(running.layer().sublayers[0].contents, nil);
    EXPECT_EQ(running.wallpaper().surfaceHealth().failed_frames, 0u);
}

// A project with no preview picture has nothing to show, and the failure is held
// and reported all the same.
TEST_F(SceneFailurePolicy, AHeldSceneWithNoPreviewStillSettlesTheHostAndShowsNothingMadeUp)
{
    LogCapture log;
    SceneBackendFaults::Instance().Arm(SceneBackendFault::Admission, "forced refusal for the test");

    Running running(WriteScene(root_ / "scene", false), root_ / "run");
    ASSERT_TRUE(running.WaitForFirstFrame());
    ExpectHeld(running, SceneFailureStage::Unsupported, "forced refusal for the test");
    EXPECT_EQ(running.layer().sublayers.count, 0u);
}

TEST_F(SceneFailurePolicy, AFailedPrepareIsHeldAndTheNextAttemptTriesNativeAgain)
{
    LogCapture log;
    SceneBackendFaults::Instance().Arm(SceneBackendFault::NativeCreate, "forced prepare failure");

    {
        Running running(WriteScene(root_ / "scene"), root_ / "run");
        ASSERT_TRUE(running.WaitForFirstFrame());
        ExpectHeld(running, SceneFailureStage::Prepare, "forced prepare failure");
        EXPECT_EQ(running.layer().sublayers.count, 1u);
        EXPECT_EQ(running.Presented(), 0u);
    }

    // Nothing was remembered against the scene: a retry really tries again, and
    // this time the native renderer is created and draws it.
    Running retry(WriteScene(root_ / "scene"), root_ / "retry");
    ASSERT_TRUE(retry.WaitForFirstFrame());
    std::this_thread::sleep_for(300ms);
    const auto selection = retry.wallpaper().sceneBackendSelection();
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;
    EXPECT_TRUE(selection.created);
    EXPECT_GT(retry.Presented(), 0u);
    EXPECT_EQ(retry.layer().sublayers.count, 0u) << "a real frame replaced the preview";
}

TEST_F(SceneFailurePolicy, AShaderThatDoesNotCompileIsHeld)
{
    LogCapture log;
    SceneBackendFaults::Instance().Arm(SceneBackendFault::NativeCompile, "forced compile failure");

    Running running(WriteScene(root_ / "scene"), root_ / "run");
    ASSERT_TRUE(running.WaitForFirstFrame());
    std::this_thread::sleep_for(300ms);
    ExpectHeld(running, SceneFailureStage::Compile, "forced compile failure");
    EXPECT_EQ(running.Presented(), 0u);
    EXPECT_EQ(running.layer().sublayers.count, 1u);
}

// A shader that cannot be compiled takes its effect out of the parsed scene. The
// scene is then not the one the author made, and is not drawn without the part:
// it is held with the shader named, once, and nothing else is drawn. The card
// under the broken effect compiles and would have drawn, so a presented frame
// is the partial picture this must not produce.
TEST_F(SceneFailurePolicy, AnEffectWhoseShaderCannotBeCompiledHoldsTheWholeScene)
{
    LogCapture log;
    Running running(
        WriteSceneWithEffect(root_ / "scene", "gl_FragColor = vec4(no_such_value, 0.0, 0.0, 1.0);"),
        root_ / "run");
    ASSERT_TRUE(running.WaitForFirstFrame()) << "the host would have waited for ever";
    std::this_thread::sleep_for(500ms);

    ExpectHeld(running, SceneFailureStage::Unsupported, "effects/tint");
    const auto selection = running.wallpaper().sceneBackendSelection();
    EXPECT_NE(selection.failure_reason.find("could not be translated to Metal"), std::string::npos)
        << selection.failure_reason;
    EXPECT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::GraphFailed);
    EXPECT_EQ(running.Presented(), 0u) << "a partial picture was drawn";
    EXPECT_EQ(running.Completed(), 0u);
    EXPECT_EQ(running.FirstFrames(), 1) << "the host is told once";
    EXPECT_EQ(running.wallpaper().surfaceHealth().failed_frames, 0u);
    ASSERT_EQ(running.layer().sublayers.count, 1u) << "the project's preview is what shows";
    EXPECT_NE(running.layer().sublayers[0].contents, nil);

    // Nothing keeps saying it once the scene is held.
    std::this_thread::sleep_for(300ms);
    EXPECT_EQ(LogCapture::Count(kFailureLine), 1) << "the failure is said once, not per frame";
}

// The same scene with an effect whose shader compiles is drawn: the refusal
// above is the shader's, not the effect chain's.
TEST_F(SceneFailurePolicy, ASceneWhoseShadersAllCompileIsNotHeld)
{
    LogCapture log;
    Running running(WriteSceneWithEffect(root_ / "scene", "gl_FragColor = c;"), root_ / "run");
    ASSERT_TRUE(running.WaitForFirstFrame());
    std::this_thread::sleep_for(500ms);

    const auto selection = running.wallpaper().sceneBackendSelection();
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;
    EXPECT_TRUE(selection.created);
    EXPECT_EQ(LogCapture::Count(kFailureLine), 0);
    EXPECT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::Running);
    EXPECT_GT(running.Presented(), 0u);
    EXPECT_EQ(running.layer().sublayers.count, 0u);
}

// A frame that fails after the scene has been drawing stops the clock, says so
// once, tells the host, and leaves the layer exactly as it was: the last frame,
// with no preview picture laid over it and nothing drawn behind it. Rebuilding
// the surface, which is what the host's recovery does, brings the scene back.
TEST_F(SceneFailurePolicy, AFrameThatFailsMidRunHoldsTheLastFrameAndReportsOnce)
{
    LogCapture log;
    Running running(WriteScene(root_ / "scene"), root_ / "run");
    ASSERT_TRUE(running.WaitForFirstFrame());
    std::this_thread::sleep_for(300ms);
    ASSERT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::Running);
    ASSERT_GT(running.Presented(), 0u);
    ASSERT_TRUE(running.wallpaper().sceneBackendSelection().created);
    ASSERT_FALSE(running.wallpaper().sceneBackendSelection().failed());

    SceneBackendFaults::Instance().Arm(SceneBackendFault::NativeDraw, "forced frame failure");
    ASSERT_TRUE(running.WaitForFailureReports(1)) << "the host was never told the scene stopped";
    std::this_thread::sleep_for(400ms);

    ExpectHeld(running, SceneFailureStage::Frame, "forced frame failure");
    EXPECT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::FrameFailed);
    EXPECT_EQ(running.wallpaper().surfaceHealth().failed_frames, 1u);
    EXPECT_EQ(running.FailureReports(), 1);
    // The picture on the layer was left alone: no more drawables, and no
    // preview over the last frame.
    const auto held = running.Presented();
    std::this_thread::sleep_for(400ms);
    EXPECT_EQ(running.Presented(), held) << "a stopped surface kept presenting";
    EXPECT_EQ(running.layer().sublayers.count, 0u);

    // The host's recovery: rebuild the surface. The failure ends with the stop.
    ASSERT_TRUE(running.Resize(1280, 720));
    std::this_thread::sleep_for(500ms);
    const auto healed = running.wallpaper().sceneBackendSelection();
    EXPECT_FALSE(healed.failed());
    EXPECT_TRUE(healed.created);
    EXPECT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::Running);
    EXPECT_GT(running.Presented(), held);

    // The next failure is a new report.
    SceneBackendFaults::Instance().Arm(SceneBackendFault::NativeDraw, "second forced failure");
    ASSERT_TRUE(running.WaitForFailureReports(2));
    EXPECT_EQ(LogCapture::Count(kFailureLine), 2);
}

// The refusal comes on a surface that is already drawing another wallpaper. The
// renderer of the outgoing scene must not survive to draw the refused one when
// the host next rebuilds the surface.
TEST_F(SceneFailurePolicy, ARefusedReloadIsNotDrawnByTheOutgoingScenesRendererAfterAResize)
{
    LogCapture log;
    Running running(WriteScene(root_ / "scene"), root_ / "run");
    ASSERT_TRUE(running.WaitForFirstFrame());
    std::this_thread::sleep_for(300ms);
    ASSERT_GT(running.Presented(), 0u);
    ASSERT_TRUE(running.wallpaper().sceneBackendSelection().created);
    ASSERT_FALSE(running.wallpaper().sceneBackendSelection().failed());

    SceneBackendFaults::Instance().Arm(SceneBackendFault::Admission, "forced refusal on reload");
    running.Reload(WriteScene(root_ / "scene-b"), root_ / "run");
    for (int i = 0; i < 200 && ! running.wallpaper().sceneBackendSelection().failed(); ++i) {
        std::this_thread::sleep_for(50ms);
    }
    std::this_thread::sleep_for(300ms);
    ExpectHeld(running, SceneFailureStage::Unsupported, "forced refusal on reload");
    const auto held = running.Presented();

    // A display change or a wake revalidation rebuilds the surface.
    EXPECT_TRUE(running.Resize(1024, 576));
    std::this_thread::sleep_for(500ms);

    const auto after = running.wallpaper().sceneBackendSelection();
    EXPECT_TRUE(after.failed()) << "the refused scene was drawn after a resize";
    EXPECT_EQ(after.failure_stage, SceneFailureStage::Unsupported);
    EXPECT_EQ(running.Presented(), held) << "the refused scene presented a frame";
    EXPECT_NE(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::Running);
    EXPECT_EQ(running.layer().sublayers.count, 0u) << "the last picture is held, no preview over it";
    EXPECT_EQ(LogCapture::Count(kFailureLine), 1);
}

// The host has released the surface and not yet given a new one back. A wallpaper
// whose load finishes in between is stored, but nothing is drawn for it, and no
// renderer is created on the layer the host gave up, until the surface returns.
TEST_F(SceneFailurePolicy, ASceneCommittedWhileTheSurfaceIsReleasedIsDrawnOnlyOnceItReturns)
{
    LogCapture              log;
    std::mutex              mutex;
    std::condition_variable changed;
    int                     commits = 0;
    Running running(WriteScene(root_ / "scene"), root_ / "run");
    ASSERT_TRUE(running.WaitForFirstFrame());
    std::this_thread::sleep_for(300ms);
    ASSERT_GT(running.Presented(), 0u);

    // Told once on registration and once for each committed scene.
    running.wallpaper().setPropertyObject(PROPERTY_POINTER_INPUT_CALLBACK,
                                          std::make_shared<PointerInputCallback>([&](bool) {
                                              std::scoped_lock lock(mutex);
                                              ++commits;
                                              changed.notify_all();
                                          }));
    ASSERT_TRUE(running.Release());
    const auto frozen = running.Completed();
    running.Reload(WriteScene(root_ / "scene-b"), root_ / "run");
    {
        std::unique_lock lock(mutex);
        ASSERT_TRUE(changed.wait_for(lock, 30s, [&] { return commits >= 2; }));
    }
    std::this_thread::sleep_for(400ms);
    EXPECT_EQ(running.Completed(), frozen) << "a frame was drawn while the surface was released";
    EXPECT_FALSE(running.wallpaper().sceneBackendSelection().failed());

    ASSERT_TRUE(running.Restore());
    for (int i = 0; i < 600 && running.FirstFrames() < 2; ++i) std::this_thread::sleep_for(50ms);
    EXPECT_EQ(running.FirstFrames(), 2) << "the new wallpaper never reached the new surface";
    EXPECT_GT(running.Completed(), frozen);
    EXPECT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::Running);
    EXPECT_FALSE(running.wallpaper().sceneBackendSelection().failed());
}

TEST_F(SceneFailurePolicy, ASurfaceTheNativeRendererCannotTakeIsHeld)
{
    LogCapture log;
    Running running(WriteScene(root_ / "scene"), root_ / "run");
    ASSERT_TRUE(running.WaitForFirstFrame());
    std::this_thread::sleep_for(300ms);
    ASSERT_GT(running.Presented(), 0u);

    SceneBackendFaults::Instance().Arm(SceneBackendFault::NativeSurface, "forced surface failure");
    EXPECT_FALSE(running.Resize(1024, 768)) << "the host is told the surface did not come back";
    ExpectHeld(running, SceneFailureStage::Surface, "forced surface failure");
}

TEST_F(SceneFailurePolicy, AnEmptyPackedSceneIsRefusedWithoutANativeFrame)
{
    const auto project = WriteEmptyPackedScene(root_ / "empty");
    ASSERT_FALSE(std::filesystem::exists(root_ / "empty/scene.json"));
    Running running(project, root_ / "run");
    // This callback also settles held parsed scenes; it is not present evidence.
    ASSERT_TRUE(running.WaitForFirstFrame());
    EXPECT_EQ(running.Presented(), 0u);
    EXPECT_EQ(running.Completed(), 0u);
    const auto selection = running.wallpaper().sceneBackendSelection();
    EXPECT_EQ(selection.failure_stage, SceneFailureStage::Unsupported);
    EXPECT_EQ(selection.failure_reason,
              "the wallpaper was parsed without the Metal translation of its shaders");
    EXPECT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::GraphFailed);
}

TEST_F(SceneFailurePolicy, AFailedReplacementStaysBlockedAcrossResizeAndAValidReloadPresentsAgain)
{
    LogCapture log;
    const auto valid = WriteScene(root_ / "scene", false);
    Running running(valid, root_ / "run");
    ASSERT_TRUE(running.WaitForFirstFrame());
    ASSERT_GT(running.Presented(), 0u);
    running.Reload(valid, root_ / "missing-shared");
    const auto deadline = std::chrono::steady_clock::now() + 5s;
    while (running.wallpaper().surfaceHealth().stop_reason != SurfaceStopReason::GraphFailed &&
           std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(5ms);
    }
    ASSERT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::GraphFailed);
    EXPECT_EQ(running.wallpaper().sceneBackendSelection().failure_reason,
              "the shared assets folder could not be mounted");
    const auto presented = running.Presented();
    const auto completed = running.Completed();
    const int first_frames = running.FirstFrames();
    ASSERT_TRUE(running.Resize(640, 360));
    // Resume and a live setting are real queued commands. Neither is a load,
    // and neither may make the failed replacement draw the outgoing scene.
    running.wallpaper().setPaused(false);
    running.wallpaper().setPropertyFloat(PROPERTY_RENDER_SCALE, 0.5f);
    // Callback installation replays on the main looper after those two writes
    // have posted their render commands. Its state outlives this test's wait.
    struct MainAck { std::mutex mutex; std::condition_variable changed; bool seen { false }; };
    const auto ack = std::make_shared<MainAck>();
    running.wallpaper().setPropertyObject(PROPERTY_POINTER_INPUT_CALLBACK,
            std::make_shared<PointerInputCallback>([ack](bool) {
                std::scoped_lock lock(ack->mutex);
                ack->seen = true;
                ack->changed.notify_all();
            }));
    {
        std::unique_lock lock(ack->mutex);
        ASSERT_TRUE(ack->changed.wait_for(lock, 5s, [&] { return ack->seen; }));
    }
    ASSERT_TRUE(running.Resize(800, 450)); // now a barrier for their render commands
    EXPECT_EQ(running.Presented(), presented);
    EXPECT_EQ(running.Completed(), completed);
    EXPECT_EQ(running.FirstFrames(), first_frames);
    EXPECT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::GraphFailed);
    EXPECT_EQ(running.wallpaper().sceneBackendSelection().failure_reason,
              "the shared assets folder could not be mounted");

    running.Reload(valid, root_ / "run");
    const auto recovered_deadline = std::chrono::steady_clock::now() + 30s;
    while (running.Presented() <= presented && std::chrono::steady_clock::now() < recovered_deadline) {
        std::this_thread::sleep_for(5ms);
    }
    EXPECT_GT(running.Presented(), presented) << "the valid reload never presented on the replacement surface";
    EXPECT_FALSE(running.wallpaper().sceneBackendSelection().failed());
    EXPECT_TRUE(running.wallpaper().sceneBackendSelection().failure_reason.empty());
    EXPECT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::Running);
}

// A surface with nothing the native renderer could adopt is a failure to report,
// not a reason to create some other renderer.
TEST_F(SceneFailurePolicy, ASurfaceWithNoMetalLayerIsAFailureToReport)
{
    LogCapture log;

    SceneWallpaper wallpaper;
    SceneWallpaperInputTestAccess::UseNullSoundOutput(wallpaper);
    ASSERT_TRUE(wallpaper.init());
    RenderInitInfo info;
    info.offscreen = true;
    wallpaper.initSurface(std::move(info));
    std::filesystem::create_directories(root_ / "run/assets");
    SceneWallpaperConfig config;
    config.source     = WriteScene(root_ / "scene").string();
    config.assets     = (root_ / "run/assets").string();
    config.cache_path = (root_ / "run/cache").string();
    config.fps        = 60;
    wallpaper.applyConfig(config);

    const auto deadline = std::chrono::steady_clock::now() + 30s;
    while (! wallpaper.sceneBackendSelection().failed() && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(20ms);
    }
    const auto selection = wallpaper.sceneBackendSelection();
    wallpaper.shutdown();
    EXPECT_TRUE(selection.failed());
    EXPECT_EQ(selection.failure_stage, SceneFailureStage::Prepare) << selection.failure_reason;
}
