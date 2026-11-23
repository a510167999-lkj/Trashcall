#import <Foundation/Foundation.h>
#import <objc/runtime.h>

__attribute__((constructor))
static void init_calldirectory_alias(void) {
    Class orig = objc_getClass("CallDirectoryHandler");
    if (orig != nil) {
        Class alias = objc_allocateClassPair(orig, "TrashcallCallDirectory.CallDirectoryHandler", 0);
        if (alias != nil) {
            objc_registerClassPair(alias);
        }
    }
}
