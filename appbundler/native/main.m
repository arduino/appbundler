/*
 * Copyright 2012, Oracle and/or its affiliates. All rights reserved.
 *
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  Oracle designates this
 * particular file as subject to the "Classpath" exception as provided
 * by Oracle in the LICENSE file that accompanied this code.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 */

#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <jni.h>

#define JAVA_LAUNCH_ERROR "JavaLaunchError"

#define JVM_RUNTIME_KEY "JVMRuntime"
#define JVM_MAIN_CLASS_NAME_KEY "JVMMainClassName"
#define JVM_OPTIONS_KEY "JVMOptions"
#define JVM_ARGUMENTS_KEY "JVMArguments"

#define UNSPECIFIED_ERROR "An unknown error occurred."

#define APP_ROOT_PREFIX "$APP_ROOT"

#define LIBJLI_DYLIB "/Library/Internet Plug-Ins/JavaAppletPlugin.plugin/Contents/Home/lib/jli/libjli.dylib"

typedef int (JNICALL *JLI_Launch_t)(int argc, char ** argv,
                                    int jargc, const char** jargv,
                                    int appclassc, const char** appclassv,
                                    const char* fullversion,
                                    const char* dotversion,
                                    const char* pname,
                                    const char* lname,
                                    jboolean javaargs,
                                    jboolean cpwildcard,
                                    jboolean javaw,
                                    jint ergo);

int launch(char *);

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    int result;
    @try {
        launch(argv[0]);
        result = 0;
    } @catch (NSException *exception) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setAlertStyle:NSCriticalAlertStyle];
        [alert setMessageText:[exception reason]];
        [alert runModal];

        result = 1;
    }

    [pool drain];

    return result;
}

int launch(char *commandName) {
    // Get the main bundle
    NSBundle *mainBundle = [NSBundle mainBundle];

    // Set the working directory to the user's home directory
    chdir([NSHomeDirectory() UTF8String]);

    // Get the main bundle's info dictionary
    NSDictionary *infoDictionary = [mainBundle infoDictionary];

    // Locate the JLI_Launch() function
    NSString *runtime = [infoDictionary objectForKey:@JVM_RUNTIME_KEY];

    JLI_Launch_t jli_LaunchFxnPtr;
    if (runtime != nil) {
        NSURL *runtimeBundleURL = [[[NSBundle mainBundle] builtInPlugInsURL] URLByAppendingPathComponent:runtime];
        CFBundleRef runtimeBundle = CFBundleCreate(NULL, (CFURLRef)runtimeBundleURL);

        NSError *bundleLoadError = nil;
        Boolean runtimeBundleLoaded = CFBundleLoadExecutableAndReturnError(runtimeBundle, (CFErrorRef *)&bundleLoadError);
        if (bundleLoadError != nil || !runtimeBundleLoaded) {
            [[NSException exceptionWithName:@JAVA_LAUNCH_ERROR
                reason:NSLocalizedString(@"JRELoadError", @UNSPECIFIED_ERROR)
                userInfo:nil] raise];
        }

        jli_LaunchFxnPtr = CFBundleGetFunctionPointerForName(runtimeBundle, CFSTR("JLI_Launch"));
    } else {
        void *libJLI = dlopen(LIBJLI_DYLIB, RTLD_LAZY);
        if (libJLI != NULL) {
            jli_LaunchFxnPtr = dlsym(libJLI, "JLI_Launch");
        }
    }

    if (jli_LaunchFxnPtr == NULL) {
        [[NSException exceptionWithName:@JAVA_LAUNCH_ERROR
            reason:NSLocalizedString(@"JRENotFound", @UNSPECIFIED_ERROR)
            userInfo:nil] raise];
    }

    // Get the main class name
    NSString *mainClassName = [infoDictionary objectForKey:@JVM_MAIN_CLASS_NAME_KEY];
    if (mainClassName == nil) {
        [[NSException exceptionWithName:@JAVA_LAUNCH_ERROR
            reason:NSLocalizedString(@"MainClassNameRequired", @UNSPECIFIED_ERROR)
            userInfo:nil] raise];
    }

    // Set the class path
    NSString *mainBundlePath = [mainBundle bundlePath];
    NSString *javaPath = [mainBundlePath stringByAppendingString:@"/Contents/Java"];
    NSMutableString *classPath = [NSMutableString stringWithFormat:@"-Djava.class.path=%@/Classes", javaPath];

    NSFileManager *defaultFileManager = [NSFileManager defaultManager];
    NSArray *javaDirectoryContents = [defaultFileManager contentsOfDirectoryAtPath:javaPath error:nil];
    if (javaDirectoryContents == nil) {
        [[NSException exceptionWithName:@JAVA_LAUNCH_ERROR
            reason:NSLocalizedString(@"JavaDirectoryNotFound", @UNSPECIFIED_ERROR)
            userInfo:nil] raise];
    }

    for (NSString *file in javaDirectoryContents) {
        if ([file hasSuffix:@".jar"]) {
            [classPath appendFormat:@":%@/%@", javaPath, file];
        }
    }

    // Set the library path
    NSString *libraryPath = [NSString stringWithFormat:@"-Djava.library.path=%@/Contents/MacOS", mainBundlePath];

    // Get the VM options
    NSArray *options = [infoDictionary objectForKey:@JVM_OPTIONS_KEY];
    if (options == nil) {
        options = [NSArray array];
    }

    // Get the application arguments
    NSArray *arguments = [infoDictionary objectForKey:@JVM_ARGUMENTS_KEY];
    if (arguments == nil) {
        arguments = [NSArray array];
    }

    // Initialize the arguments to JLI_Launch()
    int argc = 1 + [options count] + 2 + [arguments count] + 1;
    char *argv[argc];

    int i = 0;
    argv[i++] = commandName;
    argv[i++] = strdup([classPath UTF8String]);
    argv[i++] = strdup([libraryPath UTF8String]);

    for (NSString *option in options) {
        option = [option stringByReplacingOccurrencesOfString:@APP_ROOT_PREFIX withString:[mainBundle bundlePath]];
        argv[i++] = strdup([option UTF8String]);
    }

    argv[i++] = strdup([mainClassName UTF8String]);

    for (NSString *argument in arguments) {
        argument = [argument stringByReplacingOccurrencesOfString:@APP_ROOT_PREFIX withString:[mainBundle bundlePath]];
        argv[i++] = strdup([argument UTF8String]);
    }

    // Invoke JLI_Launch()
    return jli_LaunchFxnPtr(argc, argv,
                            0, NULL,
                            0, NULL,
                            "",
                            "",
                            "java",
                            "java",
                            FALSE,
                            FALSE,
                            FALSE,
                            0);
}
