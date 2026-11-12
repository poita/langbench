#include "qrcode/bit_buffer.hpp"

namespace qrcode {

void BitBuffer::append(std::uint32_t value, int count) {
    for (int i = count - 1; i >= 0; --i) {
        if ((size_ & 7) == 0) bytes_.push_back(0);
        if ((value >> i) & 1) bytes_.back() |= static_cast<std::uint8_t>(0x80 >> (size_ & 7));
        ++size_;
    }
}

void BitBuffer::appendZeros(std::size_t count) {
    size_t newSize = size_ + count;
    bytes_.resize((newSize + 7) / 8, 0);
    size_ = newSize;
}

}  // namespace qrcode
