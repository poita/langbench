#include "chip8/machine.hpp"

#include <algorithm>

#include "chip8/font.hpp"

namespace chip8 {

Machine::Machine() { std::copy(kFont.begin(), kFont.end(), mem_.begin() + kFontBase); }

void Machine::load_rom(const std::vector<std::uint8_t>& rom) {
    const std::size_t n = std::min(rom.size(), kMaxRomSize);
    std::copy_n(rom.begin(), n, mem_.begin() + kProgramBase);
}

void Machine::step() noexcept {
    const unsigned hi = mem_[pc_];
    const unsigned lo = mem_[(pc_ + 1u) & 0xFFFu];
    set_pc(pc_ + 2u);
    execute(static_cast<std::uint16_t>((hi << 8) | lo));

    if ((++cycles_ & 7u) == 0) {
        if (dt_ > 0) --dt_;
        if (st_ > 0) --st_;
    }
}

void Machine::draw(unsigned x, unsigned y, unsigned n) noexcept {
    const int sx = static_cast<int>(x & 63u);
    const int sy = static_cast<int>(y & 31u);
    bool collision = false;
    for (unsigned row = 0; row < n; ++row) {
        const unsigned byte = mem_[(i_ + row) & 0xFFFu];
        if (byte == 0) continue;
        for (int bit = 0; bit < 8; ++bit) {
            if ((byte >> (7 - bit)) & 1u) {
                collision |= display_.toggle(sx + bit, sy + static_cast<int>(row));
            }
        }
    }
    v_[0xF] = collision ? 1 : 0;
}

void Machine::execute(std::uint16_t op) noexcept {
    const unsigned x = (op >> 8) & 0xF;
    const unsigned y = (op >> 4) & 0xF;
    const unsigned n = op & 0xF;
    const unsigned nn = op & 0xFF;
    const unsigned nnn = op & 0xFFF;

    switch (op >> 12) {
        case 0x0:
            if (op == 0x00E0) {
                display_.clear();
            } else if (op == 0x00EE) {
                if (sp_ > 0) {  // popping an empty stack is unspecified; ignore it
                    --sp_;
                    set_pc(stack_[sp_]);
                }
            }
            break;
        case 0x1: set_pc(nnn); break;
        case 0x2:
            if (sp_ < kStackDepth) {  // a 17th push is unspecified; ignore it
                stack_[sp_++] = pc_;
                set_pc(nnn);
            }
            break;
        case 0x3: skip_if(v_[x] == nn); break;
        case 0x4: skip_if(v_[x] != nn); break;
        case 0x5:
            if (n == 0) skip_if(v_[x] == v_[y]);
            break;
        case 0x6: v_[x] = static_cast<std::uint8_t>(nn); break;
        case 0x7: v_[x] = static_cast<std::uint8_t>(v_[x] + nn); break;
        case 0x8: {
            const unsigned vx = v_[x];
            const unsigned vy = v_[y];
            unsigned flag = 0;
            bool has_flag = false;
            switch (n) {
                case 0x0: v_[x] = static_cast<std::uint8_t>(vy); break;
                case 0x1: v_[x] = static_cast<std::uint8_t>(vx | vy); break;
                case 0x2: v_[x] = static_cast<std::uint8_t>(vx & vy); break;
                case 0x3: v_[x] = static_cast<std::uint8_t>(vx ^ vy); break;
                case 0x4:
                    v_[x] = static_cast<std::uint8_t>(vx + vy);
                    flag = (vx + vy) > 255 ? 1 : 0;
                    has_flag = true;
                    break;
                case 0x5:
                    v_[x] = static_cast<std::uint8_t>(vx - vy);
                    flag = vx >= vy ? 1 : 0;
                    has_flag = true;
                    break;
                case 0x6:
                    v_[x] = static_cast<std::uint8_t>(vx >> 1);
                    flag = vx & 1u;
                    has_flag = true;
                    break;
                case 0x7:
                    v_[x] = static_cast<std::uint8_t>(vy - vx);
                    flag = vy >= vx ? 1 : 0;
                    has_flag = true;
                    break;
                case 0xE:
                    v_[x] = static_cast<std::uint8_t>(vx << 1);
                    flag = (vx >> 7) & 1u;
                    has_flag = true;
                    break;
                default: break;  // undefined 8XYn: no-op
            }
            if (has_flag) v_[0xF] = static_cast<std::uint8_t>(flag);  // flag written last
            break;
        }
        case 0x9:
            if (n == 0) skip_if(v_[x] != v_[y]);
            break;
        case 0xA: i_ = static_cast<std::uint16_t>(nnn); break;
        case 0xB: set_pc(nnn + v_[0]); break;
        case 0xC: v_[x] = static_cast<std::uint8_t>(rng_.next_byte() & nn); break;
        case 0xD: draw(v_[x], v_[y], n); break;
        case 0xE:
            if (nn == 0x9E) {
                skip_if((keys_ >> (v_[x] & 0xF)) & 1u);
            } else if (nn == 0xA1) {
                skip_if(!((keys_ >> (v_[x] & 0xF)) & 1u));
            }
            break;
        case 0xF:
            switch (nn) {
                case 0x07: v_[x] = dt_; break;
                case 0x0A:
                    if (keys_ != 0) {
                        unsigned k = 0;
                        while (!((keys_ >> k) & 1u)) ++k;
                        v_[x] = static_cast<std::uint8_t>(k);
                    } else {
                        set_pc(pc_ - 2u);
                    }
                    break;
                case 0x15: dt_ = v_[x]; break;
                case 0x18: st_ = v_[x]; break;
                case 0x1E: i_ = static_cast<std::uint16_t>(i_ + v_[x]); break;
                case 0x29: i_ = static_cast<std::uint16_t>(kFontBase + (v_[x] & 0xFu) * kGlyphSize); break;
                case 0x33: {
                    const unsigned v = v_[x];
                    mem_[i_ & 0xFFFu] = static_cast<std::uint8_t>(v / 100);
                    mem_[(i_ + 1u) & 0xFFFu] = static_cast<std::uint8_t>((v / 10) % 10);
                    mem_[(i_ + 2u) & 0xFFFu] = static_cast<std::uint8_t>(v % 10);
                    break;
                }
                case 0x55:
                    for (unsigned k = 0; k <= x; ++k) mem_[(i_ + k) & 0xFFFu] = v_[k];
                    break;
                case 0x65:
                    for (unsigned k = 0; k <= x; ++k) v_[k] = mem_[(i_ + k) & 0xFFFu];
                    break;
                default: break;
            }
            break;
    }
}

}  // namespace chip8
