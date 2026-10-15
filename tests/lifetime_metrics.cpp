// SPDX-License-Identifier: MIT
#include <cstdint>
#include <sys/resource.h>

// Keep the platform-specific rusage layout in the system headers.
extern "C" std::int64_t usdm_test_peak_rss() {
  rusage usage{};
  if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
#ifdef __APPLE__
  return usage.ru_maxrss;
#else
  return static_cast<std::int64_t>(usage.ru_maxrss) * 1024;
#endif
}
