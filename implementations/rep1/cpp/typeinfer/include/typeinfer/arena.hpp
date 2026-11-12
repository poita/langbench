// A simple bump-pointer arena. Objects allocated from it are never destroyed
// individually, so only trivially destructible types may live in it. This
// keeps deep syntax trees and type graphs from needing recursive destructors.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <new>
#include <span>
#include <type_traits>
#include <vector>

namespace typeinfer {

class Arena {
public:
    explicit Arena(std::size_t chunk_size = 1 << 20) : chunk_size_(chunk_size) {}
    Arena(const Arena&) = delete;
    Arena& operator=(const Arena&) = delete;

    /// Returns `size` bytes aligned to `align`.
    void* allocate(std::size_t size, std::size_t align) {
        for (;;) {
            if (current_ < chunks_.size()) {
                Chunk& c = chunks_[current_];
                auto base = reinterpret_cast<std::uintptr_t>(c.data.get());
                std::uintptr_t p = (base + offset_ + align - 1) & ~(std::uintptr_t)(align - 1);
                if (p + size <= base + c.size) {
                    offset_ = p + size - base;
                    return reinterpret_cast<void*>(p);
                }
                if (size + align > chunk_size_ && current_ + 1 == chunks_.size()) {
                    // Oversized request: give it a chunk of its own.
                    add_chunk(size + align);
                    continue;
                }
                ++current_;
                offset_ = 0;
                continue;
            }
            add_chunk(size + align > chunk_size_ ? size + align : chunk_size_);
        }
    }

    /// Constructs a trivially destructible T in the arena.
    template <class T, class... Args>
    T* create(Args&&... args) {
        static_assert(std::is_trivially_destructible_v<T>);
        return new (allocate(sizeof(T), alignof(T))) T(std::forward<Args>(args)...);
    }

    /// Allocates an uninitialised array of `n` trivially copyable Ts.
    template <class T>
    T* allocate_array(std::size_t n) {
        static_assert(std::is_trivially_destructible_v<T>);
        return static_cast<T*>(allocate(sizeof(T) * (n ? n : 1), alignof(T)));
    }

    /// Copies the elements of `src` into the arena and returns a view of the copy.
    template <class T>
    std::span<const T> copy(std::span<const T> src) {
        T* p = allocate_array<T>(src.size());
        for (std::size_t i = 0; i < src.size(); ++i) p[i] = src[i];
        return {p, src.size()};
    }
    template <class T>
    std::span<const T> copy(const std::vector<T>& src) {
        return copy(std::span<const T>(src.data(), src.size()));
    }

    /// Forgets every allocation, keeping standard-sized chunks for reuse.
    void clear() {
        std::vector<Chunk> keep;
        for (auto& c : chunks_)
            if (c.size == chunk_size_) keep.push_back(std::move(c));
        chunks_ = std::move(keep);
        current_ = 0;
        offset_ = 0;
    }

private:
    struct Chunk {
        std::unique_ptr<std::byte[]> data;
        std::size_t size;
    };
    void add_chunk(std::size_t size) {
        chunks_.push_back({std::make_unique<std::byte[]>(size), size});
        current_ = chunks_.size() - 1;
        offset_ = 0;
    }

    std::size_t chunk_size_;
    std::vector<Chunk> chunks_;
    std::size_t current_ = 0;
    std::size_t offset_ = 0;
};

}  // namespace typeinfer
