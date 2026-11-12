#include "kiln/step.hpp"

namespace kiln {

std::vector<std::string> StepDef::full_outputs() const {
  std::vector<std::string> out = outputs;
  if (!depfile.empty()) out.push_back(depfile);
  return out;
}

std::vector<std::string> StepDef::file_inputs() const {
  std::vector<std::string> out;
  for (const auto& in : inputs) {
    if (in.empty() || in[0] != '@') out.push_back(in);
  }
  return out;
}

}  // namespace kiln
