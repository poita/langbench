// Command-line front end: svgraster <input-dir> <output-dir>
//
// Reads <input-dir>/render.txt (lines "NAME WIDTH HEIGHT"), renders each SVG and
// writes <output-dir>/<NAME minus .svg>.ppm.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "svgraster/svgraster.hpp"

namespace fs = std::filesystem;

namespace {

struct Job {
    std::string name;
    int width, height;
};

bool read_file(const fs::path& p, std::string& out) {
    std::ifstream in(p, std::ios::binary);
    if (!in) return false;
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

std::vector<Job> parse_render_txt(const std::string& text) {
    std::vector<Job> jobs;
    std::istringstream in(text);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        std::istringstream fields(line);
        std::string name, w, h, extra;
        if (!(fields >> name)) continue;
        if (name[0] == '#') continue;
        if (!(fields >> w >> h) || (fields >> extra)) continue;
        try {
            jobs.push_back({name, std::stoi(w), std::stoi(h)});
        } catch (const std::exception&) {
        }
    }
    return jobs;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: " << argv[0] << " <input-dir> <output-dir>\n";
        return 2;
    }
    const fs::path in_dir = argv[1], out_dir = argv[2];
    std::error_code ec;
    fs::create_directories(out_dir, ec);

    std::string manifest;
    if (!read_file(in_dir / "render.txt", manifest)) {
        std::cerr << "cannot read " << (in_dir / "render.txt").string() << "\n";
        return 1;
    }
    int status = 0;
    for (const Job& job : parse_render_txt(manifest)) {
        if (job.width < 1 || job.height < 1) continue;
        std::string svg;
        if (!read_file(in_dir / job.name, svg)) {
            std::cerr << "cannot read " << job.name << "\n";
            status = 1;
        }
        std::string stem = job.name.size() >= 4 ? job.name.substr(0, job.name.size() - 4) : job.name;
        std::string ppm = svgraster::render_svg_to_ppm(svg, job.width, job.height);
        std::ofstream out(out_dir / (stem + ".ppm"), std::ios::binary);
        out.write(ppm.data(), static_cast<std::streamsize>(ppm.size()));
        if (!out) {
            std::cerr << "cannot write " << stem << ".ppm\n";
            status = 1;
        }
    }
    return status;
}
