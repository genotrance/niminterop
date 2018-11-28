# Package

version     = "0.1.0"
author      = "genotrance"
description = "C/C++ interop for Nim"
license     = "MIT"

bin = @["toast"]
installDirs = @["nimterop"]

# Dependencies

requires "nim >= 0.19.0", "treesitter >= 0.1.0", "treesitter_c >= 0.1.0", "treesitter_cpp >= 0.1.0", "regex >= 0.10.0"

proc execCmd(cmd:string)=
  echo cmd
  exec cmd

task test, "Test":
  # PRTEMP
  execCmd "nim c -r --experimental:codeReordering tests/tnimterop_c.nim"
  execCmd "nim cpp -r --experimental:codeReordering tests/tnimterop_cpp.nim"

task installWithDeps, "install dependencies":
  for a in ["http://github.com/genotrance/nimtreesitter?subdir=treesitter",
            "http://github.com/genotrance/nimtreesitter?subdir=treesitter_c",
            "http://github.com/genotrance/nimtreesitter?subdir=treesitter_cpp",]:
    execCmd "nimble install -y " & a
  execCmd "nimble install -y"
