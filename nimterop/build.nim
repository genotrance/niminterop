import hashes, macros, osproc, sets, strformat, strutils, tables

import os except findExe, sleep

import regex

proc sanitizePath*(path: string, noQuote = false, sep = $DirSep): string =
  result = path.multiReplace([("\\\\", sep), ("\\", sep), ("/", sep)])
  if not noQuote:
    result = result.quoteShell

proc sleep*(milsecs: int) =
  ## Sleep at compile time
  let
    cmd =
      when defined(windows):
        "cmd /c timeout "
      else:
        "sleep "

  discard gorgeEx(cmd & $(milsecs / 1000))

proc getOsCacheDir(): string =
  when defined(posix):
    result = getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache") / "nim"
  else:
    result = getHomeDir() / "nimcache"

proc getNimteropCacheDir(): string =
  result = getOsCacheDir() / "nimterop"

proc getCurrentNimCompiler*(): string =
  result = getCurrentCompilerExe()
  when defined(nimsuggest):
    result = result.replace("nimsuggest", "nim")

proc execAction*(cmd: string, retry = 0, die = true, cache = false,
                 cacheKey = ""): tuple[output: string, ret: int] =
  ## Execute an external command - supported at compile time
  ##
  ## Checks if command exits successfully before returning. If not, an
  ## error is raised. Always caches results to be used in nimsuggest or nimcheck
  ## mode.
  ##
  ## `retry` - number of times command should be retried before error
  ## `die = false` - return on errors
  ## `cache = true` - cache results unless cleared with -f
  ## `cacheKey` - key to create unique cache entry
  var
    ccmd = ""
  when defined(Windows):
    # Replace 'cd d:\abc' with 'd: && cd d:\abc`
    var filteredCmd = cmd
    if cmd.toLower().startsWith("cd"):
      var
        colonIndex = cmd.find(":")
        driveLetter = cmd.substr(colonIndex-1, colonIndex)
      if (driveLetter[0].isAlphaAscii() and
          driveLetter[1] == ':' and
          colonIndex == 4):
        filteredCmd = &"{driveLetter} && {cmd}"
    ccmd = "cmd /c " & filteredCmd
  elif defined(posix):
    ccmd = cmd
  else:
    doAssert false

  when nimvm:
    # Cache results for speedup if cache = true
    # Else cache for preserving functionality in nimsuggest and nimcheck
    let
      hash = (ccmd & cacheKey).hash().abs()
      cacheFile = getNimteropCacheDir() / "execCache" / "nimterop_" & $hash & ".txt"

    when defined(nimsuggest) or defined(nimcheck):
      # Load results from cache file if generated in previous run
      if fileExists(cacheFile):
        result.output = cacheFile.readFile()
      elif die:
        doAssert false, "Results not cached - run nim c/cpp at least once\n" & ccmd
    else:
      if cache and fileExists(cacheFile) and not compileOption("forceBuild"):
        # Return from cache when requested
        result.output = cacheFile.readFile()
      else:
        # Execute command and store results in cache
        (result.output, result.ret) = gorgeEx(ccmd)
        if result.ret == 0 or die == false:
          # mkdir for execCache dir (circular dependency)
          let dir = cacheFile.parentDir()
          if not dirExists(dir):
            let flag = when not defined(Windows): "-p" else: ""
            discard execAction(&"mkdir {flag} {dir.sanitizePath}")
          cacheFile.writeFile(result.output)
  else:
    # Used by toast
    (result.output, result.ret) = execCmdEx(ccmd)

  # On failure, retry or die as requested
  if result.ret != 0:
    if retry > 0:
      sleep(500)
      result = execAction(cmd, retry = retry - 1, die, cache, cacheKey)
    elif die:
      doAssert false, "Command failed: " & $result.ret & "\ncmd: " & ccmd &
                      "\nresult:\n" & result.output

proc findExe*(exe: string): string =
  ## Find the specified executable using the `which`/`where` command - supported
  ## at compile time
  var
    cmd =
      when defined(windows):
        "where " & exe
      else:
        "which " & exe

    (output, ret) = execAction(cmd, die = false)

  if ret == 0:
    return output.splitLines()[0].strip()

proc mkDir*(dir: string) =
  ## Create a directory at compile time
  ##
  ## The `os` module is not available at compile time so a few
  ## crucial helper functions are included with nimterop.
  if not dirExists(dir):
    let
      flag = when not defined(Windows): "-p" else: ""
    discard execAction(&"mkdir {flag} {dir.sanitizePath}", retry = 2)

proc cpFile*(source, dest: string, move=false) =
  ## Copy a file from `source` to `dest` at compile time
  let
    source = source.replace("/", $DirSep)
    dest = dest.replace("/", $DirSep)
    cmd =
      when defined(Windows):
        if move:
          "move /y"
        else:
          "copy /y"
      else:
        if move:
          "mv -f"
        else:
          "cp -f"

  discard execAction(&"{cmd} {source.sanitizePath} {dest.sanitizePath}", retry = 2)

proc mvFile*(source, dest: string) =
  ## Move a file from `source` to `dest` at compile time
  cpFile(source, dest, move=true)

proc rmFile*(source: string, dir = false) =
  ## Remove a file or pattern at compile time
  let
    source = source.replace("/", $DirSep)
    cmd =
      when defined(Windows):
        if dir:
          "rd /s/q"
        else:
          "del /s/q/f"
      else:
        "rm -rf"
    exists =
      if dir:
        dirExists(source)
      else:
        fileExists(source)

  if exists:
    discard execAction(&"{cmd} {source.sanitizePath}", retry = 2)

proc rmDir*(dir: string) =
  ## Remove a directory or pattern at compile time
  rmFile(dir, dir = true)

proc getProjectCacheDir*(name: string, forceClean = true): string =
  ## Get a cache directory where all nimterop artifacts can be stored
  ##
  ## Projects can use this location to download source code and build binaries
  ## that can be then accessed by multiple apps. This is created under the
  ## per-user Nim cache directory.
  ##
  ## Use `name` to specify the subdirectory name for a project.
  ##
  ## `forceClean` is enabled by default and effectively deletes the folder
  ## if Nim is compiled with the `-f` or `--forceBuild` flag. This allows
  ## any project to start out with a clean cache dir on a forced build.
  ##
  ## NOTE: avoid calling `getProjectCacheDir()` multiple times on the same
  ## `name` when `forceClean = true` else checked out source might get deleted
  ## at the wrong time during build.
  ##
  ## E.g.
  ##   `nimgit2` downloads `libgit2` source so `name = "libgit2"`
  ##
  ##   `nimarchive` downloads `libarchive`, `bzlib`, `liblzma` and `zlib` so
  ##   `name = "nimarchive" / "libarchive"` for `libarchive`, etc.
  result = getNimteropCacheDir() / name

  if forceClean and compileOption("forceBuild"):
    echo "# Removing " & result
    rmDir(result)

proc extractZip*(zipfile, outdir: string) =
  ## Extract a zip file using `powershell` on Windows and `unzip` on other
  ## systems to the specified output directory
  var cmd = "unzip -o $#"
  if defined(Windows):
    cmd = "powershell -nologo -noprofile -command \"& { Add-Type -A " &
          "'System.IO.Compression.FileSystem'; " &
          "[IO.Compression.ZipFile]::ExtractToDirectory('$#', '.'); }\""

  echo "# Extracting " & zipfile
  discard execAction(&"cd {outdir.sanitizePath} && {cmd % zipfile}")

proc extractTar*(tarfile, outdir: string) =
  ## Extract a tar file using `tar`, `7z` or `7za` to the specified output directory
  var
    cmd = ""
    name = ""

  if findExe("tar").len != 0:
    let
      ext = tarfile.splitFile().ext.toLowerAscii()
      typ =
        case ext
        of ".gz", ".tgz": "z"
        of ".xz": "J"
        of ".bz2": "j"
        else: ""

    cmd = "tar xvf" & typ & " " & tarfile.sanitizePath
  else:
    for i in ["7z", "7za"]:
      if findExe(i).len != 0:
        cmd = i & " x $#" % tarfile.sanitizePath

        name = tarfile.splitFile().name
        if ".tar" in name.toLowerAscii():
          cmd &= " && " & i & " x $#" % name.sanitizePath

        break

  doAssert cmd.len != 0, "No extraction tool - tar, 7z, 7za - available for " & tarfile.sanitizePath

  echo "# Extracting " & tarfile
  discard execAction(&"cd {outdir.sanitizePath} && {cmd}")
  if name.len != 0:
    rmFile(outdir / name)

proc downloadUrl*(url, outdir: string) =
  ## Download a file using `curl` or `wget` (or `powershell` on Windows) to the specified directory
  ##
  ## If an archive file, it is automatically extracted after download.
  let
    file = url.extractFilename()
    ext = file.splitFile().ext.toLowerAscii()
    archives = @[".zip", ".xz", ".gz", ".bz2", ".tgz", ".tar"]

  if not (ext in archives and fileExists(outdir/file)):
    echo "# Downloading " & file
    mkDir(outdir)
    var cmd = findExe("curl")
    if cmd.len != 0:
      cmd &= " -Lk $# -o $#"
    else:
      cmd = findExe("wget")
      if cmd.len != 0:
        cmd &= " $# -O $#"
      elif defined(Windows):
        cmd = "powershell [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; wget $# -OutFile $#"
      else:
        doAssert false, "No download tool available - curl, wget"
    discard execAction(cmd % [url, (outdir/file).sanitizePath], retry = 1)

    if ext == ".zip":
      extractZip(file, outdir)
    elif ext in archives:
      extractTar(file, outdir)

proc gitReset*(outdir: string) =
  ## Hard reset the git repository at the specified directory
  echo "# Resetting " & outdir

  let cmd = &"cd {outdir.sanitizePath} && git reset --hard"
  while execAction(cmd).output.contains("Permission denied"):
    sleep(1000)
    echo "#   Retrying ..."

proc gitCheckout*(file, outdir: string) =
  ## Checkout the specified `file` in the git repository at `outdir`
  ##
  ## This effectively resets all changes in the file and can be
  ## used to undo any changes that were made to source files to enable
  ## successful wrapping with `cImport()` or `c2nImport()`.
  echo "# Resetting " & file
  let file2 = file.relativePath outdir
  let cmd = &"cd {outdir.sanitizePath} && git checkout {file2.sanitizePath}"
  while execAction(cmd).output.contains("Permission denied"):
    sleep(500)
    echo "#   Retrying ..."

proc gitPull*(url: string, outdir = "", plist = "", checkout = "") =
  ## Pull the specified git repository to the output directory
  ##
  ## `plist` is the list of specific files and directories or wildcards
  ## to sparsely checkout. Multiple values can be specified one entry per
  ## line. It is optional and if omitted, the entire repository will be
  ## checked out.
  ##
  ## `checkout` is the git tag, branch or commit hash to checkout once
  ## the repository is downloaded. This allows for pinning to a specific
  ## version of the code.
  if dirExists(outdir/".git"):
    gitReset(outdir)
    return

  let
    outdirQ = outdir.sanitizePath

  mkDir(outdir)

  echo "# Setting up Git repo: " & url
  discard execAction(&"cd {outdirQ} && git init .")
  discard execAction(&"cd {outdirQ} && git remote add origin {url}")

  if plist.len != 0:
    # If a specific list of files is required, create a sparse checkout
    # file for git in its config directory
    let sparsefile = outdir / ".git/info/sparse-checkout"

    discard execAction(&"cd {outdirQ} && git config core.sparsecheckout true")
    writeFile(sparsefile, plist)

  if checkout.len != 0:
    echo "# Checking out " & checkout
    discard execAction(&"cd {outdirQ} && git fetch", retry = 1)
    discard execAction(&"cd {outdirQ} && git checkout {checkout}")
  else:
    echo "# Pulling repository"
    discard execAction(&"cd {outdirQ} && git pull --depth=1 origin master", retry = 1)

proc findFile*(file: string, dir: string, recurse = true, first = false, regex = false): string =
  ## Find the file in the specified directory
  ##
  ## `file` is a regular expression if `regex` is true
  ##
  ## Turn off recursive search with `recurse` and stop on first match with
  ## `first`. Without it, the shortest match is returned.
  var
    cmd =
      when defined(windows):
        "nimgrep --filenames --oneline --nocolor $1 \"$2\" $3"
      elif defined(linux):
        "find $3 $1 -regextype egrep -regex $2"
      elif defined(osx) or defined(FreeBSD):
        "find -E $3 $1 -regex $2"

    recursive = ""

  if recurse:
    when defined(windows):
      recursive = "--recursive"
  else:
    when not defined(windows):
      recursive = "-maxdepth 1"

  var
    dir = dir
    file = file
  if not recurse:
    let
      pdir = file.parentDir()
    if pdir.len != 0:
      dir = dir / pdir

    file = file.extractFilename

  cmd = cmd % [recursive, (".*[\\\\/]" & file & "$").quoteShell, dir.sanitizePath]

  let
    (files, ret) = execAction(cmd, die = false)
  if ret == 0:
    for line in files.splitLines():
      let f =
        when defined(windows):
          if ": " in line:
            line.split(": ", maxsplit = 1)[1]
          else:
            ""
        else:
          line

      if (f.len != 0 and (result.len == 0 or result.len > f.len)):
        result = f
        if first: break

proc flagBuild*(base: string, flags: openArray[string]): string =
  ## Simple helper proc to generate flags for `configure`, `cmake`, etc.
  ##
  ## Every entry in `flags` is replaced into the `base` string and
  ## concatenated to the result.
  ##
  ## E.g.
  ##   `base = "--disable-$#"`
  ##   `flags = @["one", "two"]`
  ##
  ## `flagBuild(base, flags) => " --disable-one --disable-two"`
  for i in flags:
    result &= " " & base % i

proc linkLibs*(names: openArray[string], staticLink = true): string =
  ## Create linker flags for specified libraries
  ##
  ## Prepends `lib` to the name so you only need `ssl` for `libssl`.
  var
    stat = if staticLink: "--static" else: ""
    resSet: OrderedSet[string]
  resSet.init()

  for name in names:
    let
      cmd = &"pkg-config --libs --silence-errors {stat} lib{name}"
      (libs, _) = execAction(cmd, die = false)
    for lib in libs.split(" "):
      resSet.incl lib

  if staticLink:
    resSet.incl "--static"

  for res in resSet:
    result &= " " & res

proc configure*(path, check: string, flags = "") =
  ## Run the GNU `configure` command to generate all Makefiles or other
  ## build scripts in the specified path
  ##
  ## If a `configure` script is not present and an `autogen.sh` script
  ## is present, it will be run before attempting `configure`.
  ##
  ## Next, if `configure.ac` or `configure.in` exist, `autoreconf` will
  ## be executed.
  ##
  ## `check` is a file that will be generated by the `configure` command.
  ## This is required to prevent configure from running on every build. It
  ## is relative to the `path` and should not be an absolute path.
  ##
  ## `flags` are any flags that should be passed to the `configure` command.
  if (path / check).fileExists():
    return

  echo "# Configuring " & path

  if not fileExists(path / "configure"):
    for i in @["autogen.sh", "build" / "autogen.sh"]:
      if fileExists(path / i):
        echo "#   Running autogen.sh"

        echo execAction(
          &"cd {(path / i).parentDir().sanitizePath} && bash ./autogen.sh").output

        break

  if not fileExists(path / "configure"):
    for i in @["configure.ac", "configure.in"]:
      if fileExists(path / i):
        echo "#   Running autoreconf"

        echo execAction(&"cd {path.sanitizePath} && autoreconf -fi").output

        break

  if fileExists(path / "configure"):
    echo "#   Running configure " & flags

    var
      cmd = &"cd {path.sanitizePath} && bash ./configure"
    if flags.len != 0:
      cmd &= &" {flags}"

    echo execAction(cmd).output

  doAssert (path / check).fileExists(), "# Configure failed"

proc getCmakePropertyStr(name, property, value: string): string =
  &"\nset_target_properties({name} PROPERTIES {property} \"{value}\")\n"

proc getCmakeIncludePath*(paths: openArray[string]): string =
  ## Create a `cmake` flag to specify custom include paths
  ##
  ## Result can be included in the `flag` parameter for `cmake()` or
  ## the `cmakeFlags` parameter for `getHeader()`.
  for path in paths:
    result &= path & ";"
  result = " -DCMAKE_INCLUDE_PATH=" & result[0 .. ^2].sanitizePath(sep = "/")

proc setCmakeProperty*(outdir, name, property, value: string) =
  ## Set a `cmake` property in `outdir / CMakeLists.txt` - usable in the `xxxPreBuild` hook
  ## for `getHeader()`
  ##
  ## `set_target_properties(name PROPERTIES property "value")`
  let
    cm = outdir / "CMakeLists.txt"
  if cm.fileExists():
    cm.writeFile(
      cm.readFile() & getCmakePropertyStr(name, property, value)
    )

proc setCmakeLibName*(outdir, name, prefix = "", oname = "", suffix = "") =
  ## Set a `cmake` property in `outdir / CMakeLists.txt` to specify a custom library output
  ## name - usable in the `xxxPreBuild` hook for `getHeader()`
  ##
  ## `prefix` is typically `lib`
  ## `oname` is the library name
  ## `suffix` is typically `.a`
  ##
  ## Sometimes, `cmake` generates non-standard library names - e.g. zlib compiles to
  ## `libzlibstatic.a` on Windows. This proc can help rename it to `libzlib.a` so that `getHeader()`
  ## can find it after the library is compiled.
  ##
  ## ```
  ## set_target_properties(name PROPERTIES PREFIX "prefix")
  ## set_target_properties(name PROPERTIES OUTPUT_NAME "oname")
  ## set_target_properties(name PROPERTIES SUFFIX "suffix")
  ## ```
  let
    cm = outdir / "CMakeLists.txt"
  if cm.fileExists():
    var
      str = ""
    if prefix.len != 0:
      str &= getCmakePropertyStr(name, "PREFIX", prefix)
    if oname.len != 0:
      str &= getCmakePropertyStr(name, "OUTPUT_NAME", oname)
    if suffix.len != 0:
      str &= getCmakePropertyStr(name, "SUFFIX", suffix)
    if str.len != 0:
      cm.writeFile(cm.readFile() & str)

proc setCmakePositionIndependentCode*(outdir: string) =
  ## Set a `cmake` directive to create libraries with -fPIC enabled
  let
    cm = outdir / "CMakeLists.txt"
  if cm.fileExists():
    let
      pic = "set(CMAKE_POSITION_INDEPENDENT_CODE ON)"
      cmd = cm.readFile()
    if not cmd.contains(pic):
      cm.writeFile(
        pic & "\n" & cmd
      )

proc cmake*(path, check, flags: string) =
  ## Run the `cmake` command to generate all Makefiles or other
  ## build scripts in the specified path
  ##
  ## `path` will be created since typically `cmake` is run in an
  ## empty directory.
  ##
  ## `check` is a file that will be generated by the `cmake` command.
  ## This is required to prevent `cmake` from running on every build. It
  ## is relative to the `path` and should not be an absolute path.
  ##
  ## `flags` are any flags that should be passed to the `cmake` command.
  ## Unlike `configure`, it is required since typically it will be the
  ## path to the repository, typically `..` when `path` is a subdir.
  if (path / check).fileExists():
    return

  echo "# Running cmake " & flags
  echo "#   Path: " & path

  mkDir(path)

  var
    cmd = &"cd {path.sanitizePath} && cmake {flags}"

  echo execAction(cmd).output

  doAssert (path / check).fileExists(), "# cmake failed"

proc make*(path, check: string, flags = "", regex = false) =
  ## Run the `make` command to build all binaries in the specified path
  ##
  ## `check` is a file that will be generated by the `make` command.
  ## This is required to prevent `make` from running on every build. It
  ## is relative to the `path` and should not be an absolute path.
  ##
  ## `flags` are any flags that should be passed to the `make` command.
  ##
  ## `regex` can be set to true if `check` is a regular expression.
  ##
  ## If `make.exe` is missing and `mingw32-make.exe` is available, it will
  ## be copied over to make.exe in the same location.
  if findFile(check, path, regex = regex).len != 0:
    return

  echo "# Running make " & flags
  echo "#   Path: " & path

  var
    cmd = findExe("make")

  if cmd.len == 0:
    cmd = findExe("mingw32-make")
    if cmd.len != 0:
      cpFile(cmd, cmd.replace("mingw32-make", "make"))
  doAssert cmd.len != 0, "Make not found"

  cmd = &"cd {path.sanitizePath} && make"
  if flags.len != 0:
    cmd &= &" {flags}"

  echo execAction(cmd).output

  doAssert findFile(check, path, regex = regex).len != 0, "# make failed"

proc getCompilerMode*(path: string): string =
  ## Determines a target language mode from an input filename, if one is not already specified.
  let file = path.splitFile()
  if file.ext in [".hxx", ".hpp", ".hh", ".H", ".h++", ".cpp", ".cxx", ".cc", ".C", ".c++"]:
    result = "cpp"
  elif file.ext in [".h", ".c"]:
    result = "c"

proc getGccModeArg*(mode: string): string =
  ## Produces a GCC argument that explicitly sets the language mode to be used by the compiler.
  if mode == "cpp":
    result = "-xc++"
  elif mode == "c":
    result = "-xc"

proc getCompiler*(): string =
  var
    compiler =
      when defined(gcc):
        "gcc"
      elif defined(clang):
        "clang"
      else:
        doAssert false, "Nimterop only supports gcc and clang at this time"

  result = getEnv("CC", compiler)

proc getGccPaths*(mode: string): seq[string] =
  var
    nul = when defined(Windows): "nul" else: "/dev/null"
    inc = false

    (outp, _) = execAction(&"""{getCompiler()} -Wp,-v {getGccModeArg(mode)} {nul}""", die = false)

  for line in outp.splitLines():
    if "#include <...> search starts here" in line:
      inc = true
      continue
    elif "End of search list" in line:
      break
    if inc:
      var
        path = line.strip().normalizedPath()
      if path notin result:
        result.add path

  when defined(osx):
    result.add(execAction("xcrun --show-sdk-path").output.strip() & "/usr/include")

proc getGccLibPaths*(mode: string): seq[string] =
  var
    nul = when defined(Windows): "nul" else: "/dev/null"
    linker = when defined(OSX): "-Xlinker" else: ""

    (outp, _) = execAction(&"""{getCompiler()} {linker} -v {getGccModeArg(mode)} {nul}""", die = false)

  for line in outp.splitLines():
    if "LIBRARY_PATH=" in line:
      for path in line[13 .. ^1].split(PathSep):
        var
          path = path.strip().normalizedPath()
        if path notin result:
          result.add path
      break
    elif '\t' in line:
      var
        path = line.strip().normalizedPath()
      if path notin result:
        result.add path

  when defined(osx):
    result.add "/usr/lib"

proc getStdPath(header, mode: string): string =
  for inc in getGccPaths(mode):
    result = findFile(header, inc, recurse = false, first = true)
    if result.len != 0:
      break

proc getStdLibPath(lname, mode: string): string =
  for lib in getGccLibPaths(mode):
    result = findFile(lname, lib, recurse = false, first = true, regex = true)
    if result.len != 0:
      break

proc getGitPath(header, url, outdir, version: string): string =
  doAssert url.len != 0, "No git url setup for " & header
  doAssert findExe("git").len != 0, "git executable missing"

  gitPull(url, outdir, checkout = version)

  result = findFile(header, outdir)

proc getDlPath(header, url, outdir, version: string): string =
  doAssert url.len != 0, "No download url setup for " & header

  var
    dlurl = url
  if "$#" in url or "$1" in url:
    doAssert version.len != 0, "Need version for download url"
    dlurl = url % version
  else:
    doAssert version.len == 0, "Download url does not contain version"

  downloadUrl(dlurl, outdir)

  var
    dirname = ""
  for kind, path in walkDir(outdir, relative = true):
    if kind == pcFile and path != dlurl.extractFilename():
        dirname = ""
        break
    elif kind == pcDir:
      if dirname.len == 0:
        dirname = path
      else:
        dirname = ""
        break

  if dirname.len != 0:
    for kind, path in walkDir(outdir / dirname, relative = true):
      mvFile(outdir / dirname / path, outdir / path)

  result = findFile(header, outdir)

proc getLocalPath(header, outdir: string): string =
  if outdir.len != 0:
    result = findFile(header, outdir)

proc getNumProcs(): string =
  when defined(windows):
    getEnv("NUMBER_OF_PROCESSORS").strip()
  elif defined(linux):
    execAction("nproc").output.strip()
  elif defined(macosx) or defined(FreeBSD):
    execAction("sysctl -n hw.ncpu").output.strip()
  else:
    "1"

proc buildLibrary(lname, outdir, conFlags, cmakeFlags, makeFlags: string): string =
  var
    conDeps = false
    conDepStr = ""
    cmakeDeps = false
    cmakeDepStr = ""
    lpath = findFile(lname, outdir, regex = true)
    makeFlagsProc = &"-j {getNumProcs()} {makeFlags}"
    made = false
    makePath = outdir

  if lpath.len != 0:
    return lpath

  if not fileExists(outdir / "Makefile"):
    if fileExists(outdir / "CMakeLists.txt"):
      if findExe("cmake").len != 0:
        var
          gen = ""
        when defined(windows):
          if findExe("sh").len != 0:
            let
              uname = execAction("sh -c uname -a").output.toLowerAscii()
            if uname.contains("msys"):
              gen = "MSYS Makefiles".quoteShell
            elif uname.contains("mingw"):
              gen = "MinGW Makefiles".quoteShell & " -DCMAKE_SH=\"CMAKE_SH-NOTFOUND\""
            else:
              echo "Unsupported system: " & uname
          else:
            gen = "MinGW Makefiles".quoteShell
        else:
          gen = "Unix Makefiles".quoteShell
        if findExe("ccache").len != 0:
          gen &= " -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
        makePath = outdir / "buildcache"
        cmake(makePath, "Makefile", &".. -G {gen} {cmakeFlags}")
        cmakeDeps = true
      else:
        cmakeDepStr &= "cmake executable missing"

    if not cmakeDeps:
      if findExe("bash").len != 0:
        for file in @["configure", "configure.ac", "configure.in", "autogen.sh", "build/autogen.sh"]:
          if fileExists(outdir / file):
            configure(outdir, "Makefile", conFlags)
            conDeps = true

            break
      else:
        conDepStr &= "bash executable missing"

  if fileExists(makePath / "Makefile"):
    make(makePath, lname, makeFlagsProc, regex = true)
    made = true

  var
    error = ""
  if not cmakeDeps and cmakeDepStr.len != 0:
    error &= &"cmake capable but {cmakeDepStr}\n"
  if not conDeps and conDepStr.len != 0:
    error &= &"configure capable but {conDepStr}\n"
  if error.len == 0:
    error = "No build files found in " & outdir
  doAssert cmakeDeps or conDeps or made, &"\n# Build configuration failed - {error}\n"

  result = findFile(lname, outdir, regex = true)

proc getDynlibExt(): string =
  when defined(windows):
    result = ".dll"
  elif defined(linux) or defined(FreeBSD):
    result = ".so[0-9.]*"
  elif defined(macosx):
    result = ".dylib[0-9.]*"

var
  gDefines {.compileTime.} = initTable[string, string]()

macro setDefines*(defs: static openArray[string]): untyped =
  ## Specify `-d:xxx` values in code instead of having to rely on the command
  ## line or `cfg` or `nims` files.
  ##
  ## At this time, Nim does not allow creation of `-d:xxx` defines in code. In
  ## addition, Nim only loads config files for the module being compiled but not
  ## for imported packages. This becomes a challenge when wanting to ship a wrapper
  ## library that wants to control `getHeader()` for an underlying package.
  ##
  ##   E.g. nimarchive wanting to set `-d:lzmaStatic`
  ##
  ## The consumer of nimarchive would need to set such defines as part of their
  ## project, making it inconvenient.
  ##
  ## By calling this proc with the defines preferred before importing such a module,
  ## the caller can set the behavior in code instead.
  ##
  ## .. code-block:: nim
  ##
  ##    setDefines(@["lzmaStatic", "lzmaDL", "lzmaSetVer=5.2.4"])
  ##
  ##    import lzma
  for def in defs:
    let
      nv = def.strip().split("=", maxsplit = 1)
    if nv.len != 0:
      let
        n = nv[0]
        v =
          if nv.len == 2:
            nv[1]
          else:
            ""
      gDefines[n] = v

macro clearDefines*(): untyped =
  ## Clear all defines set using `setDefines()`.
  gDefines.clear()

macro isDefined*(def: untyped): untyped =
  ## Check if `-d:xxx` is set globally or via `setDefines()`
  let
    sdef = gDefines.hasKey(def.strVal())
  result = newNimNode(nnkStmtList)
  result.add(quote do:
    when defined(`def`) or `sdef` != 0:
      true
    else:
      false
  )

macro getHeader*(header: static[string], giturl: static[string] = "", dlurl: static[string] = "", outdir: static[string] = "",
  conFlags: static[string] = "", cmakeFlags: static[string] = "", makeFlags: static[string] = "",
  altNames: static[string] = ""): untyped =
  ## Get the path to a header file for wrapping with
  ## `cImport() <cimport.html#cImport.m%2C%2Cstring%2Cstring%2Cstring>`_ or
  ## `c2nImport() <cimport.html#c2nImport.m%2C%2Cstring%2Cstring%2Cstring>`_.
  ##
  ## This proc checks `-d:xxx` defines based on the header name (e.g. lzma from lzma.h),
  ## and accordingly employs different ways to obtain the source.
  ##
  ## `-d:xxxStd` - search standard system paths. E.g. `/usr/include` and `/usr/lib` on Linux
  ## `-d:xxxGit` - clone source from a git repo specified in `giturl`
  ## `-d:xxxDL` - download source from `dlurl` and extract if required
  ##
  ## This allows a single wrapper to be used in different ways depending on the user's needs.
  ## If no `-d:xxx` defines are specified, `outdir` will be searched for the header as is.
  ##
  ## If multiple `-d:xxx` defines are specified, precedence is `Std` and then `Git` or `DL`.
  ## This allows using a system installed library if available before falling back to manual
  ## building.
  ##
  ## `-d:xxxSetVer=x.y.z` can be used to specify which version to use. It is used as a tag
  ## name for Git whereas for DL, it replaces `$1` in the URL defined.
  ##
  ## All defines can also be set in code using `setDefines()`.
  ##
  ## The library is then configured (with `cmake` or `autotools` if possible) and built
  ## using `make`, unless using `-d:xxxStd` which presumes that the system package
  ## manager was used to install prebuilt headers and binaries.
  ##
  ## The header path is stored in `const xxxPath` and can be used in a `cImport()` call
  ## in the calling wrapper. The dynamic library path is stored in `const xxxLPath` and can
  ## be used for the `dynlib` parameter (within quotes) or with `{.passL.}`.
  ##
  ## `-d:xxxStatic` can be specified to statically link with the library instead. This
  ## will automatically add a `{.passL.}` call to the static library for convenience.
  ##
  ## `conFlags`, `cmakeFlags` and `makeFlags` allow sending custom parameters to `configure`,
  ## `cmake` and `make` in case additional configuration is required as part of the build process.
  ##
  ## `altNames` is a list of alternate names for the library - e.g. zlib uses `zlib.h` for the header but
  ## the typical lib name is `libz.so` and not `libzlib.so`. However, it is libzlib.dll on Windows if built
  ## with cmake. In this case, `altNames = "z,zlib"`. Comma separate for multiple alternate names without
  ## spaces.
  ##
  ## The original header name is not included by default if `altNames` is set since it could cause the
  ## wrong lib to be selected. E.g. `SDL2/SDL.h` could pick `libSDL.so` even if `altNames = "SDL2"`.
  ## Explicitly include it in `altNames` like the `zlib` example when required.
  ##
  ## `xxxPreBuild` is a hook that is called after the source code is pulled from Git or downloaded but
  ## before the library is built. This might be needed if some initial prep needs to be done before
  ## compilation. A few values are provided to the hook to help provide context:
  ##
  ## `outdir` is the same `outdir` passed in and `header` is the discovered header path in the
  ## downloaded source code.
  ##
  ## Simply define `proc xxxPreBuild(outdir, header: string)` in the wrapper and it will get called
  ## prior to the build process.
  var
    origname = header.extractFilename().split(".")[0]
    name = origname.replace(re"[[:^alnum:]]", "")

    # -d:xxx for this header
    stdStr = name & "Std"
    gitStr = name & "Git"
    dlStr = name & "DL"

    staticStr = name & "Static"
    verStr = name & "SetVer"

    # Ident nodes of the -d:xxx to check in when statements
    nameStd = newIdentNode(stdStr)
    nameGit = newIdentNode(gitStr)
    nameDL = newIdentNode(dlStr)

    nameStatic = newIdentNode(staticStr)

    # Consts to generate
    path = newIdentNode(name & "Path")
    lpath = newIdentNode(name & "LPath")
    version = newIdentNode(verStr)
    lname = newIdentNode(name & "LName")
    preBuild = newIdentNode(name & "PreBuild")

    # Regex for library search
    lre = "(lib)?$1[_-]?(static)?[0-9.\\-]*\\"

    # If -d:xxx set with setDefines()
    stdVal = gDefines.hasKey(stdStr)
    gitVal = gDefines.hasKey(gitStr)
    dlVal = gDefines.hasKey(dlStr)
    staticVal = gDefines.hasKey(staticStr)
    verVal =
      if gDefines.hasKey(verStr):
        gDefines[verStr]
      else:
        ""
    mode = getCompilerMode(header)

  # Use alternate library names if specified for regex search
  if altNames.len != 0:
    lre = lre % ("(" & altNames.replace(",", "|") & ")")
  else:
    lre = lre % origname

  result = newNimNode(nnkStmtList)
  result.add(quote do:
    # Need to check -d:xxx or setDefines()
    const
      `nameStd`* = when defined(`nameStd`): true else: `stdVal` == 1
      `nameGit`* = when defined(`nameGit`): true else: `gitVal` == 1
      `nameDL`* = when defined(`nameDL`): true else: `dlVal` == 1
      `nameStatic`* = when defined(`nameStatic`): true else: `staticVal` == 1

    # Search for header in outdir (after retrieving code) depending on -d:xxx mode
    proc getPath(header, giturl, dlurl, outdir, version: string): string =
      when `nameGit`:
        getGitPath(header, giturl, outdir, version)
      elif `nameDL`:
        getDlPath(header, dlurl, outdir, version)
      else:
        getLocalPath(header, outdir)

    const
      `version`* {.strdefine.} = `verVal`
      `lname` =
        when `nameStatic`:
          `lre` & ".a"
        else:
          `lre` & getDynlibExt()

      # Look in standard path if requested by user
      stdPath =
        when `nameStd`: getStdPath(`header`, `mode`) else: ""
      stdLPath =
        when `nameStd`: getStdLibPath(`lname`, `mode`) else: ""

      # Look elsewhere if requested while prioritizing standard paths
      prePath =
        when stdPath.len != 0 and stdLPath.len != 0:
          stdPath
        else:
          getPath(`header`, `giturl`, `dlurl`, `outdir`, `version`)

    # Run preBuild hook before building library if not standard
    when (prePath != stdPath or prePath.len == 0) and declared(`preBuild`):
      static:
        `preBuild`(`outdir`, prePath)

    const
      # Library binary path - build if not standard
      `lpath`* =
        when stdPath.len != 0 and stdLPath.len != 0:
          stdLPath
        else:
          buildLibrary(`lname`, `outdir`, `conFlags`, `cmakeFlags`, `makeFlags`)

      # Header path - search again in case header is generated in build
      `path`* =
        if prePath.len != 0:
          prePath
        else:
          getPath(`header`, `giturl`, `dlurl`, `outdir`, `version`)

    static:
      doAssert `path`.len != 0, "\nHeader " & `header` & " not found - " & "missing/empty outdir or -d:$1Std -d:$1Git or -d:$1DL not specified" % `name`
      doAssert `lpath`.len != 0, "\nLibrary " & `lname` & " not found"
      echo "# Including library " & `lpath`

    # Automatically link with static libary
    when `nameStatic`:
      {.passL: `lpath`.}
  )
