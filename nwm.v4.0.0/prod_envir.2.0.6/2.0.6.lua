local envir = os.getenv("envir") or "prod"
local OPSFS = os.getenv("OPSFS") or "h1"
local OPSFSssd = os.getenv("OPSFSssd") or "f1"
local COMFS = os.getenv("COMFS") or "h1"
local DATAFS = os.getenv("DATAFS") or "f1"
local DCOMFS = os.getenv("DCOMFS") or "h1"
local DBNETFS = os.getenv("DBNETFS") or "h1"
local PACKAGESFS = os.getenv("PACKAGESFS") or "h1"

setenv("OPSROOT",os.getenv("OPSROOT") or pathJoin("/contrib/lfs",OPSFS,"ops",envir))
setenv("OPSROOTssd",os.getenv("OPSROOTssd") or pathJoin("/contrib/lfs",OPSFSssd,"ops",envir))

setenv("COMROOT",os.getenv("COMROOT") or pathJoin("/contrib/lfs",COMFS,"ops",envir,"com"))

setenv("DATAROOT",os.getenv("DATAROOT") or pathJoin("/contrib/lfs",DATAFS,"ops",envir,"tmp"))

setenv("DCOMROOT",os.getenv("DCOMROOT") or pathJoin("/contrib/lfs",DCOMFS,"ops","prod","dcom"))

setenv("PACKAGEROOT",os.getenv("PACKAGEROOT") or pathJoin("/contrib/lfs",PACKAGESFS,"ops",envir,"packages"))

setenv("SIPHONROOT",os.getenv("SIPHONROOT") or pathJoin("/contrib/lfs",DBNETFS,"ops",envir,"dbnet_siphon"))
