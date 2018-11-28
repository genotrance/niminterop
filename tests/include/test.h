#include <stdint.h>

#define TEST_INT 512
#define TEST_FLOAT 5.12
#define TEST_HEX 0x512

#ifdef __APPLE__
int foo1;
#define myvar1 10
#else
double foo2;
#define myvar1 20
#endif

#define myvar 33

#define myvar2(x) \
  x * myvar1

typedef uint8_t PRIMTYPE;
typedef PRIMTYPE CUSTTYPE;

struct STRUCT1 {
	int field1;
};

typedef struct STRUCT1 STRUCT2;

typedef struct {
	int field1;
} STRUCT3;

enum ENUM {
	enum1,
	enum2,
	enum3
};

typedef enum {
	enum4 = 3,
	enum5,
	enum6
} ENUM2;

typedef void * VOIDPTR;
typedef int * INTPTR;

typedef struct {
	int *field;
} STRUCT4;

int test_call_int();
struct STRUCT1 _test_call_int_param_(int param1);
STRUCT2 test_call_int_param2(int param1, STRUCT2 param2);
STRUCT2 test_call_int_param3(int param1, struct STRUCT1 param2);
ENUM2 test_call_int_param4(enum ENUM param1);
