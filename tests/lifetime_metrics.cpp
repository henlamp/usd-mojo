// SPDX-License-Identifier: MIT
#include <cstdint>
#include <sys/resource.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <malloc/malloc.h>
#else
#include <cstdio>
#include <unistd.h>
#include <malloc.h>
#endif

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

extern "C" std::int64_t usdm_test_current_rss() {
#ifdef __APPLE__
  mach_task_basic_info_data_t info{};
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) return -1;
  return static_cast<std::int64_t>(info.resident_size);
#else
  auto *file = std::fopen("/proc/self/statm", "r");
  if (!file) return -1;
  unsigned long pages = 0, resident = 0;
  const auto fields = std::fscanf(file, "%lu %lu", &pages, &resident);
  std::fclose(file);
  return fields == 2 ? static_cast<std::int64_t>(resident) * sysconf(_SC_PAGESIZE) : -1;
#endif
}

extern "C" std::int64_t usdm_test_live_allocated() {
#ifdef __APPLE__
  malloc_statistics_t stats{};
  malloc_zone_statistics(malloc_default_zone(), &stats);
  return static_cast<std::int64_t>(stats.size_in_use);
#elif defined(__GLIBC_PREREQ) && __GLIBC_PREREQ(2, 33)
  const auto stats = mallinfo2();
  return static_cast<std::int64_t>(stats.uordblks) + stats.hblkhd;
#else
  return -1;
#endif
}
