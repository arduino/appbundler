/*
 * This file is part of Arduino app launcher for MacOSX.
 *
 * Copyright 2020 Arduino SA (www.arduino.cc)
 */

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

#include <Cocoa/Cocoa.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <jni.h>

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

void openURL(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
    [workspace openURL:url];
}

NSString *runCommand(NSString *path, NSArray *args) {
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:path];
    [task setArguments:args];
    [task setStandardOutput:outPipe];
    [task setStandardError:errPipe];
    [task setStandardInput:[NSPipe pipe]];
    [task launch];
    [task waitUntilExit];

    NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
    NSString *out = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
    NSString *err = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
    return [[out stringByAppendingString:@"\n"] stringByAppendingString:err];
}

NSString *bundlePath = nil;     // substituted on $APP_ROOT
NSString *jvmRuntimePath = nil; // substituted on $JVM_RUNTIME
NSString *expandVariables(NSString *in) {
    if (bundlePath != nil) {
        in = [in stringByReplacingOccurrencesOfString:@"$APP_ROOT"    withString:bundlePath];
    }
    if (jvmRuntimePath != nil) {
        in = [in stringByReplacingOccurrencesOfString:@"$JVM_RUNTIME" withString:jvmRuntimePath];
    }
    return in;
}

void displayNoJREFoundAlert() {
    CFOptionFlags result;
    CFUserNotificationDisplayAlert(0, kCFUserNotificationNoteAlertLevel,
                NULL, NULL, NULL,
                CFSTR("Oracle Java 8 not found"),
                CFSTR("Oracle Java 8 is required to run the Arduino IDE.\nClick 'Download Java' to open the website and download the required package."),
                CFSTR("Download Java"), // "Default" Button
                CFSTR("More info..."),  // "Alternate" Button
                CFSTR("Close"),         // "Other" Button
                &result);
    switch (result) {
        case kCFUserNotificationDefaultResponse:
            openURL(@("https://www.java.com/download/"));
            break;
        case kCFUserNotificationAlternateResponse:
            openURL(@("https://arduino.cc/"));
            break;
        case kCFUserNotificationOtherResponse:
            break;
        default:
            break;
    }
}

/**
 * Extract the Java major version number from a string.
 * Expected input "1.X", "1.X.Y_ZZ" or "jkd1.X.Y_ZZ", returns X or 0 if not found.
 */
int extractJavaMajorVersion(NSString *vstring) {
    if (vstring == nil) {
        return 0;
    }
    NSUInteger vstart = [vstring rangeOfString:@"1."].location;
    if (vstart == NSNotFound) {
        return 0;
    }
    vstring = [vstring substringFromIndex:(vstart+2)];
    NSUInteger vdot = [vstring rangeOfString:@"."].location;
    if (vdot == NSNotFound) {
        return [vstring intValue];
    }
    vstring = [vstring substringToIndex:vdot];
    return [vstring intValue];
}

NSMutableArray *extractJarListFromPath(NSString *javaPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *list = [fm contentsOfDirectoryAtPath:javaPath error:nil];
    if (list == nil) {
        return nil;
    }

    NSMutableArray *res = [NSMutableArray new];
    //[res addObject:[NSString stringWithFormat:@"%@/Classes", javaPath]];
    for (NSString *file in list) {
        if ([file hasSuffix:@".jar"]) {
            [res addObject:[NSString stringWithFormat:@"%@/%@", javaPath, file]];
        }
    }
    return res;
}

NSString *retrieveKnownDir(NSUInteger what) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(what, NSUserDomainMask, YES);
    return [paths objectAtIndex:0];
}

void launchError(NSString *msg) {
    [[NSException exceptionWithName:@"JavaLaunchError" reason:msg userInfo:nil] raise];
}

NSString *findJLIlibInPath(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *jdkPath = [path stringByAppendingPathComponent:@"jre/lib/jli/libjli.dylib"];
    if ([fm fileExistsAtPath:jdkPath]) {
        return jdkPath;
    }

    NSString *jrePath = [path stringByAppendingPathComponent:@"lib/jli/libjli.dylib"];
    if ([fm fileExistsAtPath:jrePath]) {
        return jrePath;
    }
    return nil;
}

NSString *checkJREInPath(NSString *path) {
    @try {
        NSLog(@"Search for java VM in '%@'", path);
        NSString *output = runCommand([path stringByAppendingPathComponent:@"bin/java"],
                                      @[@"-version"]);
        if (output == nil) {
            NSLog(@"  KO - running 'java -version' produced no output");
            return nil;
        }
        NSRange vrange = [output rangeOfString:@"java version \"1."];
        if (vrange.location == NSNotFound) {
            NSLog(@"  KO - invalid 'java -version' output");
            return nil;
        }
        NSString *vstring = [output substringFromIndex:(vrange.location + 14)];
        vrange  = [vstring rangeOfString:@"\""];
        if (vrange.location == NSNotFound) {
            NSLog(@"  KO - invalid 'java -version' output");
            return nil;
        }
        vstring = [vstring substringToIndex:vrange.location];
        int version = extractJavaMajorVersion(vstring);
        if (version != 8) {
            NSLog(@"  KO - found java version %@ (major=%d)", vstring, version);
            return nil;
        }
        // Check paths for JRE and JDK
        NSString *res = findJLIlibInPath(path);
        if (res == nil) {
            NSLog(@"  KO - could not find libjli.dylib inside JDK/JRE path");
        }

        jvmRuntimePath = path;
        if ([jvmRuntimePath hasSuffix:@"/Contents/Home"]) {
            jvmRuntimePath = [jvmRuntimePath stringByDeletingLastPathComponent];
            jvmRuntimePath = [jvmRuntimePath stringByDeletingLastPathComponent];
        }
        return res;
    } @catch (NSException *exception) {
        NSLog(@"  KO - error: '%@'", [exception reason]);
        return nil;
    }
}

/**
 * Searches for a JDK dylib of the specified version or later.
 */
NSString *findJDKDylib() {
    @try {
        NSString *outRead = runCommand(@"/usr/libexec/java_home", @[@"-v", @"1.8"]);

        // If matching JDK not found, outRead will include something like
        // "Unable to find any JVMs matching version "1.X"."
        if ([outRead rangeOfString:@"Unable"].location != NSNotFound) {
            NSLog(@"No matching JDK found.");
            return nil;
        }
        return checkJREInPath([outRead stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    } @catch (NSException *exception) {
        NSLog (@"JDK search exception: '%@'", [exception reason]);
    }

    return nil;
}

/**
 * Searches for a JRE or JDK dylib of the specified version or later.
 * First checks the "usual" JRE location, and failing that looks for a JDK.
 */
NSString *findJavaDylib() {
    NSLog (@"Searching for a Java 8 virtual machine");

    // First check if the JRE is found in /Library/Internet Plug-Ins/JavaAppletPlugin.plugin
    // where usually Orcale Java 8 is installed by default.
    NSString *r = checkJREInPath(@"/Library/Internet Plug-Ins/JavaAppletPlugin.plugin/Contents/Home");
    if (r != nil) {
        return r;
    }

    // Having failed to find a JRE in the usual location, see if a JDK is installed
    // (probably in /Library/Java/JavaVirtualMachines). If so, return address of
    // dylib in the JRE within the JDK.
    return findJDKDylib();
}

int launcherMain(const char *commandName, int progargc, char *progargv[]) {
    // Extract information from bundle manifest
    NSBundle *bundle = [NSBundle mainBundle];
    NSDictionary *plist = [bundle infoDictionary];
    NSString *jvmRuntime = [plist objectForKey:@"JVMRuntime"];
    // Set globals for variable substitution in expandeVariables() as soon as possible
    bundlePath = [bundle bundlePath];
    if ([bundlePath rangeOfString:@":"].location != NSNotFound) {
        launchError(@"Bundle path contains colon!");
    }
    jvmRuntimePath = [[bundle builtInPlugInsPath] stringByAppendingPathComponent:jvmRuntime];
    NSString *bundleName = [plist objectForKey:@"CFBundleName"];
    NSString *workingDir = [plist objectForKey:@"WorkingDirectory"];
    if (workingDir == nil) {
        workingDir = [[NSFileManager defaultManager] currentDirectoryPath];
    }
    workingDir = expandVariables(workingDir);
    NSString *mainClassName = [plist objectForKey:@"JVMMainClassName"];
    if (mainClassName == nil) {
        launchError(@"JVMMainClassName required!");
    }
    NSArray *jvmOptions = [plist objectForKey:@"JVMOptions"];
    if (jvmOptions == nil) {
        jvmOptions = [NSArray array];
    }
    NSArray *jvmArguments = [plist objectForKey:@"JVMArguments"];
    if (jvmArguments == nil) {
        jvmArguments = [NSArray array];
    }
    NSArray *jvmClassPath = [plist objectForKey:@"JVMClassPath"];
    NSDictionary *jvmDefaultOptions = [plist objectForKey:@"JVMDefaultOptions"];
    bool searchSystemJVM = ([plist objectForKey:@"SearchSystemJVM"] != nil);

    // Print bundle information
    NSLog(@"Loading Application '%@'", bundleName);
    NSLog(@"JVMRuntime=%@", jvmRuntime);
    NSLog(@"CFBundleName=%@", bundleName);
    NSLog(@"WorkingDirectory=%@", [plist objectForKey:@"WorkingDirectory"]);
    NSLog(@"JVMMainClassName=%@", mainClassName);
    NSLog(@"JVMOptions=%@", jvmOptions);
    NSLog(@"JVMArguments=%@", jvmArguments);
    NSLog(@"JVMClasspath=%@", jvmClassPath);
    NSLog(@"JVMDefaultOptions=%@", jvmDefaultOptions);
    NSLog(@"SearchSystemJVM=%@", searchSystemJVM ? @"true" : @"false");
    NSLog(@"-> Bundle path: %@", bundlePath);
    NSLog(@"-> Working Directory: '%@'", workingDir);
    NSLog(@"-> JVM Runtime path: %@", jvmRuntimePath);

    // Change working dir
    chdir([workingDir UTF8String]);

    // Search JVM
    NSString *javaDylib = nil;
    if (searchSystemJVM) {
        javaDylib = findJavaDylib();
    }
    if (javaDylib != nil) {
        NSLog(@"-> JVM Runtime path updated to: %@", jvmRuntimePath);
    } else if (jvmRuntime != nil) {
        javaDylib = findJLIlibInPath([jvmRuntimePath stringByAppendingPathComponent:@"Contents/Home"]);
    }
    if (javaDylib == nil) {
        displayNoJREFoundAlert();
        return 1;
    }
    NSLog(@"-> Java Runtime Dylib Path: '%@'", [javaDylib stringByStandardizingPath]);

    const char *libjliPath = [javaDylib fileSystemRepresentation];
    void *libJLI = dlopen(libjliPath, RTLD_LAZY);
    JLI_Launch_t jli_LaunchFxnPtr = NULL;
    if (libJLI != NULL) {
        jli_LaunchFxnPtr = dlsym(libJLI, "JLI_Launch");
    }
    if (jli_LaunchFxnPtr == NULL) {
        launchError(@"Error loading Java.");
    }

    // Build java.class.path
    if (jvmClassPath == nil) {
        // If not specified generate classpath from Contents/Java content
        jvmClassPath = extractJarListFromPath([bundlePath stringByAppendingString:@"/Contents/Java"]);
        if (jvmClassPath == nil) {
            launchError(@"Java directory not found");
        }
    }
    NSString *javaClassPath = [jvmClassPath componentsJoinedByString:@":"];
    
    // Set the library path
    NSString *javaLibraryPath = [NSString stringWithFormat:@"%@/Contents/MacOS", bundlePath];

    // Get the VM default options
    NSArray *defaultOptions = [NSArray array];
    if (jvmDefaultOptions != nil) {
        NSMutableDictionary *defaults = [NSMutableDictionary dictionaryWithDictionary: jvmDefaultOptions];
        // Replace default options with user specific options, if available
        NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
        // Create special key that should be used by Java's java.util.Preferences impl
        // Requires us to use "/" + bundleIdentifier.replace('.', '/') + "/JVMOptions/" as node on the Java side
        // Beware: bundleIdentifiers shorter than 3 segments are placed in a different file!
        // See java/util/prefs/MacOSXPreferences.java of OpenJDK for details
        NSString *bundleDictionaryKey = [bundle bundleIdentifier];
        bundleDictionaryKey = [bundleDictionaryKey stringByReplacingOccurrencesOfString:@"." withString:@"/"];
        bundleDictionaryKey = [NSString stringWithFormat: @"/%@/", bundleDictionaryKey];

        NSDictionary *bundleDictionary = [userDefaults dictionaryForKey: bundleDictionaryKey];
        if (bundleDictionary != nil) {
            NSDictionary *jvmOptionsDictionary = [bundleDictionary objectForKey: @"JVMOptions/"];
            for (NSString *key in jvmOptionsDictionary) {
                NSString *value = [jvmOptionsDictionary objectForKey:key];
                [defaults setObject: value forKey: key];
            }
        }
        defaultOptions = [defaults allValues];
    }

    // Get OSX special folders
    NSString *libraryDir = retrieveKnownDir(NSLibraryDirectory);
    NSString *documentsDir = retrieveKnownDir(NSDocumentDirectory);
    NSString *applicationSupportDir = retrieveKnownDir(NSApplicationSupportDirectory);
    NSString *cachesDir = retrieveKnownDir(NSCachesDirectory);
    NSString *containersDir = [libraryDir stringByAppendingPathComponent:@"Containers"];
    BOOL isDir;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL containersDirExists = [fm fileExistsAtPath:containersDir isDirectory:&isDir];
    BOOL sandboxed = (containersDirExists && isDir);

    // Build JVM arguments...
    NSMutableArray *args = [NSMutableArray new];
    [args addObject:@(commandName)];
    [args addObject:[@"-Djava.class.path=" stringByAppendingString:javaClassPath]];
    [args addObject:[@"-Djava.library.path=" stringByAppendingString:javaLibraryPath]];
    [args addObject:[@"-DLibraryDirectory=" stringByAppendingString:libraryDir]];
    [args addObject:[@"-DDocumentsDirectory=" stringByAppendingString:documentsDir]];
    [args addObject:[@"-DApplicationSupportDirectory=" stringByAppendingString:applicationSupportDir]];
    [args addObject:[@"-DCachesDirectory=" stringByAppendingString:cachesDir]];
    [args addObject:[@"-DSandboxEnabled=" stringByAppendingString:(sandboxed ? @"true" : @"false")]];
    [args addObjectsFromArray:jvmOptions];
    [args addObjectsFromArray:defaultOptions];
    [args addObject:mainClassName];
    [args addObjectsFromArray:jvmArguments];
    for (int i = 0; i < progargc; i++) {
        [args addObject:@(progargv[i])];
    }
    unsigned long argc = [args count];
    char *argv[argc];
    for (int i=0; i<argc; i++) {
        argv[i] = strdup([expandVariables([args objectAtIndex:i]) UTF8String]);
    }
    
    // Print the full command line for debugging purposes
    NSLog(@"Command line passed to application argc=%ld:", argc);
    for (int i = 0; i < argc; i++) {
        NSLog(@"Arg %d: '%s'", i, argv[i]);
    }

    // Launch JVM
    return jli_LaunchFxnPtr((int)argc, argv,
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

static bool argsTaken = false;
static int argsCount;
static char **argsValue;

int main(int argc, char *argv[]) {
    @autoreleasepool {
        @try {
            if (!argsTaken) {
                argsTaken = true;
                argsCount = argc;
                argsValue = argv;
            }
            launcherMain(argv[0], argsCount - 1, &argsValue[1]);
            return 0;
        } @catch (NSException *exception) {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setAlertStyle:NSCriticalAlertStyle];
            [alert setMessageText:[exception reason]];
            [alert runModal];
            return 1;
        }
    }
}

