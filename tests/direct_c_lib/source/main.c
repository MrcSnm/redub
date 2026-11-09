#include <mathlib/mathlib.h>
#include <stdio.h>

int main(void)
{
	int result = math_add(math_mul(2, 3), math_scale(4));
	printf("%d\n", result);
	return result == 22 ? 0 : 1;
}
