#include <mathlib/mathlib.h>

int math_scale(int value)
{
#ifdef MATHLIB_ENABLE_SCALE
	return value * 4;
#else
	return value;
#endif
}
