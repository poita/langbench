#include <filesystem>
#include <fstream>
#include <set>
#include <unistd.h>
#include <sstream>

#include "driver.hpp"
#include "test_util.hpp"

namespace fs = std::filesystem;
using namespace linalg;

namespace {

class DriverTest : public ::testing::Test {
protected:
    void SetUp() override {
        root = fs::temp_directory_path() / ("linalg_driver_test_" + std::to_string(::getpid()));
        fs::remove_all(root);
        fs::create_directories(root / "in");
        fs::create_directories(root / "out");
    }
    void TearDown() override { fs::remove_all(root); }

    void put(const std::string& name, const std::string& text) {
        std::ofstream(root / "in" / name, std::ios::binary) << text;
    }
    std::string get(const std::string& name) {
        std::ifstream in(root / "out" / name, std::ios::binary);
        std::ostringstream ss;
        ss << in.rdbuf();
        return ss.str();
    }
    std::set<std::string> outputs() {
        std::set<std::string> names;
        for (const auto& e : fs::directory_iterator(root / "out")) names.insert(e.path().filename().string());
        return names;
    }

    fs::path root;
};

}  // namespace

TEST(ParseScript, SkipsBlankAndCommentLines) {
    const auto cmds = cli::parse_script("# hi\n\n  add \t a.mtx   b.mtx  \n\t# indented comment\r\ndet a.mtx\n");
    ASSERT_EQ(cmds.size(), 2u);
    EXPECT_EQ(cmds[0], (std::vector<std::string>{"add", "a.mtx", "b.mtx"}));
    EXPECT_EQ(cmds[1], (std::vector<std::string>{"det", "a.mtx"}));
}

TEST_F(DriverTest, SpecWorkedExample) {
    put("commands.txt", "# a two by two example\nadd a.mtx b.mtx\n\ndet a.mtx\nchol s.mtx\n");
    put("a.mtx", "%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n");
    put("b.mtx", "%%MatrixMarket matrix coordinate real general\n2 2 2\n1 1 0.5\n2 2 -1.5\n");
    put("s.mtx", "%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n");
    EXPECT_EQ(cli::run_script(root / "in", root / "out"), 3u);
    EXPECT_EQ(outputs(), (std::set<std::string>{"001_add.mtx", "002_det.mtx", "003_chol_L.mtx"}));
    EXPECT_EQ(get("001_add.mtx"),
              "%%MatrixMarket matrix array real general\n2 2\n"
              "1.5000000000e+00\n3.0000000000e+00\n2.0000000000e+00\n2.5000000000e+00\n");
    EXPECT_EQ(get("002_det.mtx"), "%%MatrixMarket matrix array real general\n1 1\n-2.0000000000e+00\n");
    EXPECT_EQ(get("003_chol_L.mtx"),
              "%%MatrixMarket matrix array real general\n2 2\n"
              "2.0000000000e+00\n1.0000000000e+00\n0.0000000000e+00\n2.0000000000e+00\n");
}

TEST_F(DriverTest, ErrorsWriteOnlyErrorFileAndScriptContinues) {
    put("commands.txt", "chol r.mtx\nnorm1 r.mtx\nsolve r.mtx r.mtx\n");
    put("r.mtx", "%%MatrixMarket matrix array real general\n2 3\n1\n2\n3\n4\n5\n6\n");
    cli::run_script(root / "in", root / "out");
    EXPECT_EQ(outputs(), (std::set<std::string>{"001_error.txt", "002_norm1.mtx", "003_error.txt"}));
    EXPECT_EQ(get("001_error.txt"), "not_square\n");
    EXPECT_EQ(get("003_error.txt"), "not_square\n");
}

TEST_F(DriverTest, MultiFileResultNames) {
    put("commands.txt", "lu a.mtx\neig a.mtx\nsvd a.mtx\nqr a.mtx\n");
    put("a.mtx", "%%MatrixMarket matrix array real symmetric\n2 2\n2\n1\n3\n");
    cli::run_script(root / "in", root / "out");
    EXPECT_EQ(outputs(), (std::set<std::string>{
                             "001_lu_P.mtx", "001_lu_L.mtx", "001_lu_U.mtx", "002_eig_w.mtx", "002_eig_V.mtx",
                             "003_svd_U.mtx", "003_svd_S.mtx", "003_svd_V.mtx", "004_qr_Q.mtx", "004_qr_R.mtx"}));
}
