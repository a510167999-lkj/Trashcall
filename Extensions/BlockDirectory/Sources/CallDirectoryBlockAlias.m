#import <Foundation/Foundation.h>
#import <objc/runtime.h>

__attribute__((constructor))
static void init_blockdirectory_alias(void) {
    Class orig = objc_getClass("CallDirectoryBlockHandler");
    if (orig != nil) {
        Class alias = objc_allocateClassPair(orig, "TrashcallBlockDirectory.CallDirectoryBlockHandler", 0);
        if (alias != nil) {
            objc_registerClassPair(alias);
        }
    }
}
