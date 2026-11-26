// SPDX-License-Identifier: GPL-2.0-or-later
#include "camera.hpp"
#include <chrono>

namespace uml::platform {
namespace {
class LegacyUnavailableCamera final : public Camera {
public:
    std::vector<CameraInfo> cameras() const override { return {}; }
    std::vector<std::vector<std::size_t>> concurrentSets() const override { return {}; }
    std::string hostModel() const override { return "legacy-iOS"; }
    std::uint64_t now() const noexcept override {
        return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
    }
    std::unique_ptr<Nv12Transformer> makeFrameTransformer() const override {
        return makePortableNv12Transformer();
    }
    std::unique_ptr<CameraSession> openSession(CameraSessionDelegate&) override { return {}; }
};
}
std::unique_ptr<Camera> makeAppleCamera() {
    return std::make_unique<LegacyUnavailableCamera>();
}
} // namespace uml::platform
