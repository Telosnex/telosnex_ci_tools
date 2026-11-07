// The test program of actions/android-arm64-chroot (ci.yml): C++ with
// libc++, bionic and libm, and an exit code that the test checks.
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

int main(int argc, char **argv) {
  std::vector<std::string> args(argv + 1, argv + argc);
  std::printf("arm64 chroot: %zu args, sqrt(2)=%.6f\n", args.size(),
              std::sqrt(2.0));
  return args.empty() ? 0 : std::stoi(args[0]);
}
