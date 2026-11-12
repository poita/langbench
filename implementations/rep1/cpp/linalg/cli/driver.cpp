#include "driver.hpp"

#include <cstdio>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>

#include "linalg/linalg.hpp"

namespace linalg::cli {
namespace {

using Args = std::vector<const Matrix*>;
using Results = std::vector<std::pair<std::string, Matrix>>;  // (file suffix, matrix)

Matrix scalar(double v) {
    Matrix m(1, 1);
    m(0, 0) = v;
    return m;
}

Matrix column(const std::vector<double>& v) {
    Matrix m(v.size(), 1);
    for (std::size_t i = 0; i < v.size(); ++i) m(i, 0) = v[i];
    return m;
}

struct Operation {
    std::size_t arity;
    std::function<Results(const Args&)> run;
};

const std::map<std::string, Operation>& operations() {
    static const std::map<std::string, Operation> ops = {
        {"add", {2, [](const Args& a) { return Results{{"add", add(*a[0], *a[1])}}; }}},
        {"mul", {2, [](const Args& a) { return Results{{"mul", multiply(*a[0], *a[1])}}; }}},
        {"transpose", {1, [](const Args& a) { return Results{{"transpose", transpose(*a[0])}}; }}},
        {"lu", {1, [](const Args& a) {
             LU f = lu_factor(*a[0]);
             return Results{{"lu_P", f.P}, {"lu_L", f.L}, {"lu_U", f.U}};
         }}},
        {"det", {1, [](const Args& a) { return Results{{"det", scalar(determinant(*a[0]))}}; }}},
        {"inv", {1, [](const Args& a) { return Results{{"inv", inverse(*a[0])}}; }}},
        {"solve", {2, [](const Args& a) { return Results{{"solve", solve(*a[0], *a[1])}}; }}},
        {"qr", {1, [](const Args& a) {
             QR f = qr_factor(*a[0]);
             return Results{{"qr_Q", f.Q}, {"qr_R", f.R}};
         }}},
        {"chol", {1, [](const Args& a) { return Results{{"chol_L", cholesky(*a[0])}}; }}},
        {"eig", {1, [](const Args& a) {
             SymmetricEigen e = eig_symmetric(*a[0]);
             return Results{{"eig_w", column(e.w)}, {"eig_V", e.V}};
         }}},
        {"svd", {1, [](const Args& a) {
             SVD f = svd(*a[0]);
             return Results{{"svd_U", f.U}, {"svd_S", column(f.s)}, {"svd_V", f.V}};
         }}},
        {"lstsq", {2, [](const Args& a) { return Results{{"lstsq", lstsq(*a[0], *a[1])}}; }}},
        {"norm1", {1, [](const Args& a) { return Results{{"norm1", scalar(norm1(*a[0]))}}; }}},
        {"norminf", {1, [](const Args& a) { return Results{{"norminf", scalar(norm_inf(*a[0]))}}; }}},
        {"normfro", {1, [](const Args& a) { return Results{{"normfro", scalar(norm_fro(*a[0]))}}; }}},
        {"cond", {1, [](const Args& a) { return Results{{"cond", scalar(cond(*a[0]))}}; }}},
    };
    return ops;
}

std::string strip(const std::string& s) {
    const char* ws = " \t\r\n";
    const auto b = s.find_first_not_of(ws);
    if (b == std::string::npos) return {};
    return s.substr(b, s.find_last_not_of(ws) - b + 1);
}

std::string command_prefix(std::size_t number) {
    char buf[16];
    std::snprintf(buf, sizeof buf, "%03zu_", number);
    return buf;
}

void write_text(const std::filesystem::path& path, const std::string& text) {
    std::ofstream out(path, std::ios::binary);
    out << text;
    if (!out) throw std::runtime_error("cannot write " + path.string());
}

}  // namespace

std::vector<std::vector<std::string>> parse_script(const std::string& text) {
    std::vector<std::vector<std::string>> commands;
    std::istringstream in(text);
    std::string line;
    while (std::getline(in, line)) {
        line = strip(line);
        if (line.empty() || line[0] == '#') continue;
        std::vector<std::string> tokens;
        std::string cur;
        for (char c : line) {
            if (c == ' ' || c == '\t') {
                if (!cur.empty()) tokens.push_back(std::move(cur)), cur.clear();
            } else {
                cur += c;
            }
        }
        if (!cur.empty()) tokens.push_back(std::move(cur));
        commands.push_back(std::move(tokens));
    }
    return commands;
}

std::size_t run_script(const std::filesystem::path& input_dir, const std::filesystem::path& output_dir) {
    std::ifstream in(input_dir / "commands.txt", std::ios::binary);
    if (!in) throw std::runtime_error("cannot open commands.txt");
    std::ostringstream ss;
    ss << in.rdbuf();
    const auto commands = parse_script(ss.str());

    std::map<std::string, Matrix> cache;  // each matrix file is parsed once
    auto load = [&](const std::string& name) -> const Matrix& {
        auto it = cache.find(name);
        if (it == cache.end())
            it = cache.emplace(name, read_matrix_market_file((input_dir / name).string())).first;
        return it->second;
    };

    std::size_t number = 0;
    for (const auto& tokens : commands) {
        ++number;
        const std::string prefix = command_prefix(number);
        try {
            const auto it = operations().find(tokens[0]);
            if (it == operations().end() || tokens.size() != it->second.arity + 1)
                throw std::invalid_argument("bad command: " + tokens[0]);
            Args args;
            for (std::size_t i = 1; i < tokens.size(); ++i) args.push_back(&load(tokens[i]));
            try {
                for (const auto& [suffix, m] : it->second.run(args))
                    write_matrix_market_file((output_dir / (prefix + suffix + ".mtx")).string(), m);
            } catch (const Error& e) {
                write_text(output_dir / (prefix + "error.txt"), std::string(e.what()) + "\n");
            }
        } catch (const std::exception& e) {
            std::cerr << "command " << number << ": " << e.what() << "\n";
        }
    }
    return number;
}

}  // namespace linalg::cli
