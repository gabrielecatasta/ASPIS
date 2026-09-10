#!/usr/bin/env bash

SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; do 
    DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
    SOURCE=$(readlink "$SOURCE")
    [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE 
done
DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )

# Default values
output_file="out"
build_dir="."
llvm_bin=$(dirname "$(which clang 2> /dev/null)" 2> /dev/null)
cuda_bin=$(dirname "$(which nvcc 2> /dev/null)" 2> /dev/null)
gpu_arch="sm_86" # Default architecture
dup=0 # 0 = eddi
cfc=0 # 0 = cfcss
eddi_options="-S"
cfc_options="-S"
clang_options=""
input_files=""
verbose=false
cleanup=true
cuspis_path="$DIR/cuspis/"

# Fallback for cuda_bin
if [[ -z "$cuda_bin" || ! -d "$cuda_bin" ]]; then
    if [[ -d "/usr/local/cuda/bin" ]]; then
        cuda_bin="/usr/local/cuda/bin"
    else
        cuda_bin=""
    fi
fi

# Colors
if [ -t 1 ]; then
	ncolors=$(tput colors)
	if test -n "$ncolors" && test $ncolors -ge 8; then
		color_red="$(tput setaf 1)"
		color_green="$(tput setaf 2)"
		color_bold="$(tput bold)"
		color_normal="$(tput sgr0)"
	fi
fi

error_msg () {
    echo -e "\n${color_red}ERROR:${color_normal}" $@
    exit 1
}

success_msg() {
    echo -e "${color_green}\xE2\x9C\x94" $@ "${color_normal}"
}

title_msg () {
    echo -e "\n${color_bold}===" $@ "===${color_normal}"
}

# Parse arguments
parse_state=0
raw_opts="$@"

for opt in $raw_opts; do
    case $parse_state in
        0)
            case $opt in
                -h | --help)
                    echo "Usage: aspis_cuda.sh [options] file.cu..."
                    echo "Options:"
                    echo "  -o <file>           Output file"
                    echo "  --gpu-arch <arch>   CUDA GPU architecture (default: sm_70)"
                    echo "  --llvm-bin <path>   Path to LLVM binaries"
                    echo "  --cuda-bin <path>   Path to CUDA binaries (nvcc, fatbinary)"
                    echo "  --build-dir <path>  Build directory"
                    echo "  --eddi, --seddi, --fdsc, --no-dup"
                    echo "  --cfcss, --rasm, --inter-rasm, --no-cfc"
                    echo "  -v, --verbose"
                    echo "  -g                  Enable debugging symbols"
                    echo "  --no-cleanup"
                    exit 0
                    ;;
                -v | --verbose) verbose=true ;;
                -o*) 
                    if [[ ${#opt} -eq 2 ]]; then parse_state=1; else output_file=`echo "$opt" | cut -b 2`; fi 
                    ;;
                --llvm-bin*)
                    if [[ ${#opt} -eq 10 ]]; then parse_state=3; else llvm_bin=`echo "$opt" | cut -b 10`; fi
                    ;;
                --cuda-bin*)
                    if [[ ${#opt} -eq 10 ]]; then parse_state=8; else cuda_bin=`echo "$opt" | cut -d'=' -f2`; fi
                    ;;
                --build-dir*)
                    if [[ ${#opt} -eq 11 ]]; then parse_state=6; else build_dir=`echo "$opt" | cut -b 10`; fi
                    ;;
                --gpu-arch*)
                    if [[ ${#opt} -eq 10 ]]; then parse_state=7; else gpu_arch=`echo "$opt" | cut -b 10`; fi
                    ;;
                --eddi) dup=0 ;;
                --seddi) dup=1 ;;
                --fdsc) dup=2 ;;
                --no-dup) dup=-1 ;;
                --cfcss) cfc=0 ;;
                --rasm) cfc=1 ;;
                --inter-rasm) cfc=2 ;;
                --no-cfc) cfc=-1 ;;
                -g)
                    clang_options="$clang_options -g"
                    eddi_options="$eddi_options --debug-enabled=true"
                    ;;
                --no-cleanup) cleanup=false ;;
                *.cu) input_files="$input_files $opt" ;;
                *) clang_options="$clang_options $opt" ;;
            esac
            ;;
        1) output_file="$opt"; parse_state=0 ;;
        3) llvm_bin="$opt"; parse_state=0 ;;
        6) build_dir="$opt"; parse_state=0 ;;
        7) gpu_arch="$opt"; parse_state=0 ;;
        8) cuda_bin="$opt"; parse_state=0 ;;
    esac
done

# Setup tools
CLANG="${llvm_bin}/clang++"
OPT="${llvm_bin}/opt"
LLVM_LINK="${llvm_bin}/llvm-link"
LLC="${llvm_bin}/llc"
NVCC="${cuda_bin}/nvcc"

# Check if nvcc exists, otherwise try to find it in PATH
if [[ ! -x "$NVCC" ]]; then
    if which nvcc >/dev/null 2>&1; then
        NVCC="nvcc"
    else
        error_msg "nvcc not found. Please ensure CUDA is installed and in your PATH, or specify --cuda-bin."
    fi
fi

# Determine CUDA home
if [[ -z "$cuda_bin" && "$NVCC" == "nvcc" ]]; then
    cuda_bin=$(dirname "$(which nvcc)")
fi
cuda_home=$(dirname "$cuda_bin")

# Explicitly add CUDA include path to fix missing headers
clang_options="$clang_options -I${cuda_home}/include"

# Add CUSPIS include path
if [[ -n "$cuspis_path" ]]; then
    clang_options="$clang_options -I$cuspis_path"
fi

if [[ $verbose == true ]]; then
    exe() { echo -e "\t\$ $@"; "$@"; if [[ $? -ne 0 ]]; then error_msg "Command FAILED: $@"; fi }
else
    exe() { "$@"; if [[ $? -ne 0 ]]; then error_msg "Command FAILED: $@"; fi }
fi

# Main execution
if [[ -z ${input_files} ]]; then error_msg "No input files provided."; fi

exe mkdir -p $build_dir
if [[ $cleanup == true ]]; then
    exe rm -f $build_dir/*.ll $build_dir/*.ptx $build_dir/*.fatbin $build_dir/*.o
fi

title_msg "Compiling Device Code to IR"

device_ir_files=""
for input_file in $input_files; do
    filename=$(basename "$input_file" | sed 's/\.[^.]*$//')
    exe $CLANG $clang_options -x cuda --cuda-path="$cuda_home" --cuda-gpu-arch=$gpu_arch --cuda-device-only -emit-llvm -S "$input_file" -o "$build_dir/${filename}_device.ll" -O0 -Xclang -disable-O0-optnone
    device_ir_files="$device_ir_files $build_dir/${filename}_device.ll"
done

exe $LLVM_LINK $device_ir_files -o $build_dir/device_linked.ll

title_msg "Applying ASPIS Passes to Device Code"

exe $OPT --enable-new-pm=1 --passes="lowerswitch" $build_dir/device_linked.ll -o $build_dir/device_linked.ll

if [[ dup -ne -1 ]]; then
    exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="func-ret-to-ref" $build_dir/device_linked.ll -o $build_dir/device_linked.ll
fi

case $dup in
    0) exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="eddi-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $eddi_options ;;
    1) exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libSEDDI.so --passes="eddi-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $eddi_options ;;
    2) exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libFDSC.so --passes="eddi-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $eddi_options ;;
esac

exe $OPT --enable-new-pm=1 --passes="simplifycfg" $build_dir/device_linked.ll -o $build_dir/device_linked.ll

case $cfc in
    0) exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libCFCSS.so --passes="cfcss-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $cfc_options ;;
    1) exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libRASM.so --passes="rasm-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $cfc_options ;;
    2) exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libINTER_RASM.so --passes="rasm-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $cfc_options ;;
esac

if [[ dup -ne -1 ]]; then
    exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="duplicate-globals" $build_dir/device_linked.ll -o $build_dir/device_linked.ll -S $eddi_options
fi

title_msg "Compiling Device IR to PTX and Fatbinary"

exe $LLC -march=nvptx64 -mcpu=$gpu_arch $build_dir/device_linked.ll -o $build_dir/device.ptx

exe $NVCC -fatbin -arch=$gpu_arch $build_dir/device.ptx -o $build_dir/device.fatbin

title_msg "Compiling Host Code"

host_objects=""
for input_file in $input_files; do
    filename=$(basename "$input_file" | sed 's/\.[^.]*$//')
    exe $CLANG $clang_options -x cuda --cuda-path="$cuda_home" --cuda-host-only --cuda-gpu-arch=$gpu_arch -Xclang -fcuda-include-gpubinary -emit-llvm -S -Xclang $build_dir/device.fatbin -c "$input_file" -o "$build_dir/${filename}_host.ll"
    host_objects="$host_objects $build_dir/${filename}_host.ll"
done

exe $LLVM_LINK $host_objects -o $build_dir/host_linked.ll

title_msg "Applying ASPIS Passes to Host Code"

case $dup in
    0) exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="eddi-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $eddi_options ;;
    1) exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libSEDDI.so --passes="eddi-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $eddi_options ;;
    2) exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libFDSC.so --passes="eddi-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $eddi_options ;;
esac

case $cfc in
    0) exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libCFCSS.so --passes="cfcss-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $cfc_options ;;
    1) exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libRASM.so --passes="rasm-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $cfc_options ;;
    2) exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libINTER_RASM.so --passes="rasm-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $cfc_options ;;
esac

if [[ dup -ne -1 ]]; then
    exe $OPT --enable-new-pm=1 -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="duplicate-globals" $build_dir/host_linked.ll -o $build_dir/host_linked.ll -S $eddi_options
fi

title_msg "Linking"

if [[ -d "${cuda_home}/lib64" ]]; then
    cuda_lib_dir="${cuda_home}/lib64"
else
    cuda_lib_dir="${cuda_home}/lib"
fi

exe $CLANG $clang_options $build_dir/host_linked.ll -o $output_file -L"$cuda_lib_dir" -Wl,-rpath,"$cuda_lib_dir" -lcudart -ldl -lrt -lpthread

if [[ $cleanup == true ]]; then
    rm -f $build_dir/*.ll $build_dir/*.ptx $build_dir/*.fatbin $build_dir/*.o
    success_msg "Cleaned cached files."
fi

success_msg "Done! Output: $output_file"