// The Luby restart sequence.
#pragma once

namespace sat {

/// Returns luby(y, i) for i >= 0: y^k where k follows the sequence
/// 0,0,1,0,0,1,2,0,0,1,0,0,1,2,3,... so for y = 2: 1,1,2,1,1,2,4,1,1,2,...
double luby(double y, int i);

}  // namespace sat
