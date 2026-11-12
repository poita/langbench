// A non-owning, non-allocating reference to a callable (internal).
#pragma once

#include <memory>
#include <type_traits>
#include <utility>

namespace jq::detail {

template <class Sig>
class FunctionRef;

template <class R, class... Args>
class FunctionRef<R(Args...)> {
 public:
  template <class F, class = std::enable_if_t<!std::is_same_v<std::decay_t<F>, FunctionRef>>>
  FunctionRef(F&& f) noexcept
      : obj_(const_cast<void*>(static_cast<const void*>(std::addressof(f)))),
        call_([](void* o, Args... args) -> R {
          return (*static_cast<std::remove_reference_t<F>*>(o))(std::forward<Args>(args)...);
        }) {}

  R operator()(Args... args) const { return call_(obj_, std::forward<Args>(args)...); }

 private:
  void* obj_;
  R (*call_)(void*, Args...);
};

}  // namespace jq::detail
