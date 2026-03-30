# AGENTS.md

Coding agent instructions for the Android Container Experiment project.

## Project Overview

This project reproduces and studies the "Binder handle invalidation after container snapshot restore" problem in Android containers (e.g., ReDroid). When an Android container is snapshotted and restored, Binder handles held by running apps become invalid.

## Project Structure

```
android-container-experiment/
├── scripts/              # Shell scripts for environment and container management
│   ├── setup-env.sh      # Environment setup (requires root)
│   ├── redroid-manage.sh # ReDroid container lifecycle management
│   ├── checkpoint-restore.sh # Snapshot/restore experiment automation
│   ├── collect-logs.sh   # Debug log collection
│   └── fix-binder-devices.sh # Binder device node repair
├── test-app/
│   └── BinderTestApp/    # Android test application (Java)
│       ├── app/
│       │   ├── build.gradle
│       │   └── src/main/java/com/experiment/bindertest/
│       │       ├── MainActivity.java
│       │       ├── BinderTestReceiver.java
│       │       └── BinderMonitorService.java
│       ├── build.gradle
│       └── settings.gradle
└── docs/                 # Documentation
```

## Build Commands

### Android App

```bash
cd test-app/BinderTestApp

# Build debug APK (requires Android SDK and ANDROID_HOME set)
./gradlew assembleDebug

# Build release APK
./gradlew assembleRelease

# Clean build
./gradlew clean

# APK output location:
# app/build/outputs/apk/debug/app-debug.apk
```

### Shell Scripts

No build required. Scripts are executable bash scripts.

```bash
# Make scripts executable if needed
chmod +x scripts/*.sh
```

## Test Commands

This project does not have traditional unit tests. The Android app itself is a test tool for Binder functionality.

### Manual Testing

```bash
# Run the full experiment workflow
./scripts/checkpoint-restore.sh run-experiment

# Quick Binder functionality test
./scripts/checkpoint-restore.sh quick-test

# Test specific Binder service via ADB
adb -s localhost:5555 shell am broadcast \
    -a com.experiment.bindertest.TEST_BINDER \
    -n com.experiment.bindertest/.BinderTestReceiver

# Collect debug logs
./scripts/collect-logs.sh all
```

### Verify Environment

```bash
sudo ./scripts/setup-env.sh --verify
```

## Lint and Typecheck

### Android App

```bash
cd test-app/BinderTestApp

# Run lint
./gradlew lint

# Lint reports:
# app/build/reports/lint-results.html

# Note: lint is configured with abortOnError false in build.gradle
```

### Shell Scripts

No formal linter configured. Follow conventions below.

## Code Style Guidelines

### Shell Scripts (Bash)

**Shebang and Options:**
```bash
#!/bin/bash
#
# Brief description of the script
#

set -e  # Exit on error
```

**Logging Functions:**
```bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}
```

**Function Style:**
- Use snake_case for function names: `start_container()`, `check_adb_connected()`
- Group related functions with comment headers
- Return 0 for success, non-zero for failure
- Use local variables: `local var="value"`

**Variable Naming:**
- Constants at top: `CONTAINER_NAME="${REDROID_CONTAINER_NAME:-redroid-experiment}"`
- Use `${VAR:-default}` for defaults from environment
- Quote all variables: `"$var"` not `$var`

**Conditionals:**
```bash
if [[ condition ]]; then
    # code
fi

# Check command existence
if command -v docker &> /dev/null; then
    # docker available
fi

# Check file/directory
if [[ -f "$file" ]]; then
    # file exists
fi
```

**Error Handling:**
- Use `set -e` at script start
- Check required commands early
- Provide helpful error messages with `log_error`
- Suggest corrective actions in error output

### Java (Android)

**Imports:**
- Group imports by package (android.*, java.*, third-party)
- No wildcard imports
- Alphabetical within groups

```java
import android.app.Activity;
import android.content.Context;
import android.os.Bundle;

import java.util.List;
import java.util.Map;

import com.example.package.Class;
```

**Naming Conventions:**
- Classes: PascalCase: `MainActivity`, `BinderTestReceiver`
- Methods: camelCase: `performBinderTest()`, `initServices()`
- Constants: SCREAMING_SNAKE_CASE: `TAG`, `TEST_INTERVAL_MS`
- Member variables: camelCase with m prefix optional: `statusTextView`, `activityManager`
- Local variables: camelCase: `successCount`, `failCount`

**Logging:**
```java
private static final String TAG = "BinderTest";

Log.d(TAG, "Debug message");
Log.i(TAG, "Info message");
Log.w(TAG, "Warning message");
Log.e(TAG, "Error message", exception);
```

**Class Structure:**
1. Static constants (TAG, intervals, etc.)
2. Instance variables (views, handlers, state)
3. Lifecycle methods (onCreate, onStart, onDestroy)
4. Public methods
5. Private helper methods
6. Inner classes/interfaces

**Error Handling:**
```java
try {
    activityManager.getMemoryClass();
} catch (DeadObjectException e) {
    Log.e(TAG, "Binder handle invalid", e);
    handleBinderFailure(e);
} catch (RemoteException e) {
    Log.e(TAG, "Remote call failed", e);
} catch (Exception e) {
    Log.e(TAG, "Unexpected error", e);
}
```

**Comments:**
- Use Javadoc for public classes and methods
- Chinese comments are acceptable in this project
- Explain "why", not "what"

```java
/**
 * Test Activity - Verifies if Binder handles become invalid after container restore
 */
public class MainActivity extends Activity {
```

**Indentation and Formatting:**
- 4 spaces for indentation (no tabs)
- Opening brace on same line
- Maximum line length: 100 characters
- Blank line between method groups

### Gradle Files

**build.gradle Structure:**
- plugins block first
- android block with namespace, compileSdk, defaultConfig
- buildTypes
- compileOptions
- dependencies last

**Dependency Format:**
```groovy
dependencies {
    implementation 'androidx.appcompat:appcompat:1.6.1'
}
```

## Common Patterns

### Container Management

```bash
# Check container is running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    # running
fi

# Wait for ADB
adb connect localhost:${ADB_PORT}
adb -s localhost:${ADB_PORT} wait-for-device
```

### Binder Testing in Java

```java
private void testServiceBinder() throws Exception {
    Class<?> serviceManager = Class.forName("android.os.ServiceManager");
    Method getService = serviceManager.getMethod("getService", String.class);
    
    IBinder binder = (IBinder) getService.invoke(null, "activity");
    if (binder == null || !binder.isBinderAlive()) {
        throw new DeadObjectException("Binder is dead");
    }
}
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REDROID_CONTAINER_NAME` | `redroid-experiment` | Container name |
| `REDROID_IMAGE` | `redroid/redroid:12.0.0_64only-latest` | Docker image |
| `REDROID_ADB_PORT` | `5555` | ADB port mapping |
| `REDROID_DATA_DIR` | `~/redroid-data` | Persistent data directory |
| `ANDROID_HOME` | - | Android SDK path (for builds) |

## Important Notes

1. **Root Required**: `setup-env.sh` requires root for kernel module loading
2. **Privileged Mode**: ReDroid container runs in `--privileged` mode for binder access
3. **No CRIU Required**: Docker commit is sufficient for this experiment
4. **Chinese Documentation**: Comments and docs may be in Chinese - maintain consistency
5. **Android SDK**: Required for building the test app, not for running experiments
