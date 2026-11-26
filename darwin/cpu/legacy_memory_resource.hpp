// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

// Apple's libc++ PMR runtime symbols are absent on older iOS releases.
// Keep the narrow allocation interface used by the gadget builders local.
#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <Availability.h>
#endif
#if defined(__APPLE__) && TARGET_OS_IPHONE && __IPHONE_OS_VERSION_MIN_REQUIRED < 170000
#include <algorithm>
#include <cstddef>
#include <cstdlib>
#include <memory>
#include <new>
#include <vector>

namespace uml::compat::pmr {
class memory_resource {
public:
    virtual ~memory_resource() = default;
    void* allocate(std::size_t n, std::size_t alignment = alignof(std::max_align_t)) {
        return do_allocate(n, alignment);
    }
    void deallocate(void* p, std::size_t n, std::size_t alignment = alignof(std::max_align_t)) {
        do_deallocate(p, n, alignment);
    }
protected:
    virtual void* do_allocate(std::size_t, std::size_t) = 0;
    virtual void do_deallocate(void*, std::size_t, std::size_t) = 0;
};

class heap_resource final : public memory_resource {
    void* do_allocate(std::size_t n, std::size_t alignment) override {
        void* p = nullptr;
        alignment = std::max(alignment, sizeof(void*));
        if (posix_memalign(&p, alignment, std::max(n, std::size_t{1})) != 0)
            throw std::bad_alloc();
        return p;
    }
    void do_deallocate(void* p, std::size_t, std::size_t) override { std::free(p); }
};
inline memory_resource* new_delete_resource() noexcept {
    static heap_resource resource;
    return &resource;
}
inline memory_resource* get_default_resource() noexcept { return new_delete_resource(); }

class monotonic_buffer_resource final : public memory_resource {
public:
    monotonic_buffer_resource(void* buffer, std::size_t bytes)
        : buffer_(static_cast<std::byte*>(buffer)), size_(bytes) {}
    monotonic_buffer_resource(const monotonic_buffer_resource&) = delete;
    monotonic_buffer_resource& operator=(const monotonic_buffer_resource&) = delete;
    ~monotonic_buffer_resource() override { release(); }
    void release() noexcept {
        for (void* p : overflow_) std::free(p);
        overflow_.clear();
        used_ = 0;
    }
private:
    void* do_allocate(std::size_t n, std::size_t alignment) override {
        n = std::max(n, std::size_t{1});
        void* p = buffer_ + used_;
        std::size_t remaining = size_ - used_;
        if (std::align(alignment, n, p, remaining)) {
            used_ = size_ - remaining + n;
            return p;
        }
        p = new_delete_resource()->allocate(n, alignment);
        try { overflow_.push_back(p); }
        catch (...) { std::free(p); throw; }
        return p;
    }
    void do_deallocate(void*, std::size_t, std::size_t) override {}
    std::byte* buffer_;
    std::size_t size_;
    std::size_t used_{};
    std::vector<void*> overflow_;
};
} // namespace uml::compat::pmr
#else
#include <memory_resource>
namespace uml::compat { namespace pmr = std::pmr; }
#endif
