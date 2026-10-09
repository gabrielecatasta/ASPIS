#!/usr/bin/env bash

SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
    DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
    SOURCE=$(readlink "$SOURCE")
    [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )

parse_state=0
output_file="out"
config_file=""
exclude_file=""
excluded_files=""
asm_file=""
asm_files=""
input_files=""
clang_options=
eddi_options="-S"
cfc_options="-S"
llvm_bin=$(dirname "$(which clang)")
cuda_bin=$(dirname "$(which nvcc 2> /dev/null)" 2> /dev/null)
gpu_arch="sm_86" # Default architecture
cuspis_path="$DIR/cuspis/"
cuda_mode=false
suffix=""
build_dir="."
dup=0 # 0 = eddi,   1 = seddi,  2 = fdsc
cfc=0 # 0 = cfcss,  1 = rasm,   2 = inter-rasm
debug_enabled=false
verbose=false
cleanup=true
libstdcpp_added=false
enable_profiling=false

# Fallback for cuda_bin
if [[ -z "$cuda_bin" || ! -d "$cuda_bin" ]]; then
    if [[ -d "/usr/local/cuda/bin" ]]; then
        cuda_bin="/usr/local/cuda/bin"
    else
        cuda_bin=""
    fi
fi

# Check if the shell supports colors
if [ -t 1 ]; then
	ncolors=$(tput colors)
	if test -n "$ncolors" && test $ncolors -ge 8; then
		color_bold="$(tput bold)"
		color_underline="$(tput smul)"
		color_standout="$(tput smso)"
		color_normal="$(tput sgr0)"
		color_black="$(tput setaf 0)"
		color_red="$(tput setaf 1)"
		color_green="$(tput setaf 2)"
		color_yellow="$(tput setaf 3)"
		color_blue="$(tput setaf 4)"
		color_magenta="$(tput setaf 5)"
		color_cyan="$(tput setaf 6)"
		color_white="$(tput setaf 7)"
	fi
fi

error_msg () {
    # Print error message
    echo -e "\n${color_red}ERROR:${color_normal}" $@
    exit 1
}

success_msg() {
    echo -e "${color_green}\xE2\x9C\x94" $@ "${color_normal}"
}

title_msg () {
    echo -e "\n${color_bold}===" $@ "===${color_normal}"
}


perform_platform_checks() {
    if [ ! -f $1 ]; then
        error_msg "\nCommand clang not found. Expected path: ${1}. Please check --llvm-bin parameter."
    fi

    if [ ! -f $2 ]; then
        error_msg "\nCommand opt not found. Expected path: ${2}. Please check --llvm-bin parameter."
    fi

    if [ ! -f $3 ]; then
        error_msg "\nCommand llvm-link not found. Expected path: ${3}. Please check --llvm-bin parameter."
    fi
    
}


parse_commands() {

    raw_opts="$@"

    for opt in $raw_opts; do
        case $parse_state in
            0)
                case $opt in
                    -h | --help)
                        cat <<-EOF 
    .-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-====-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-.
    |                          _____ _____ _____  _____                |
    !                   /\    / ____|  __ \_   _|/ ____|               !
    :                  /  \  | (___ | |__) || | | (___                 :
    :                 / /\ \  \___ \|  ___/ | |  \___ \                :
    .                / ____ \ ____) | |    _| |_ ____) |               .
    :               /_/    \_\_____/|_|   |_____|_____/                :
    :                                                                  :
    !  ASPIS: Automatic Software-based Protection and Integrity Suite  !
    |                                                                  |
    '--.. .- -. . .-.. .-.. .- -.-. ..- .-.. ---=-=-=-=-=-=-=-=-=-=-=-='

    Usage: aspis.sh [options] file(s)...

    The specified files can be any C source code files. 
    By default, the compiler performs EDDI+CFCSS hardening.

    Options:
        -h, --help          Display available options.
        -v, --verbose       Turn on verbose mode
        -o <file>           Write the compilation output to <file>.
        --build-dir <path>  Specify the directory where to place all the build
                            files.
        --llvm-bin  <path>  Set the path to the llvm binaries (clang, opt, 
                            llvm-link) to <path>.
        --suffix    <value> Set the suffix of the binaries used (clang, opt, 
                            llvm-link) to <value>.
        --exclude   <file>  Set the files to exclude from the compilation. The 
                            content of <file> is the list of files to 
                            exclude, one for each line (wildcard * allowed).
        --asmfiles  <file>  Defines the set of assembly files required for the
                            compilation. The content of <file> is the list of 
                            assembly files to pass to the linker at compilation 
                            termination, one for each line (wildcard * allowed).   
        --no-cleanup        Does not remove the intermediate .ll files generated,
                            which might be useful for debug purposes.

    Hardening mechanism:
        --eddi              (Default) Enable EDDI.
        --reddi             Enable Recursive-EDDI.
        --seddi             Enable Selective-EDDI.
        --fdsc              Enable Full Duplication with Selective Checking.
        --no-dup            Completely disable data duplication.

        --cfcss             (Default) Enable CFCSS.
        --rasm              Enable RASM.
        --inter-rasm        Enable inter-RASM with the default signature -0xDEAD.
        --racfed            Enable RACFED.
        --no-cfc            Completely disable control-flow checking.

    Hardening options:
        --alternate-memmap  When set, alternates the definition of original and 
                            duplicate variables. By default they are allocated in 
                            groups maximizing the distance between original and
                            duplicated value.

        --enable-profiling  When set, enable the insertion of profiling function calls 
                            at synchonization points, which can be used to trace where
                            consistency checks are executed.

        --multiple-errbb    Enables multiple error basic blocks in EDDI

        --coarse-grained    Enables coarse-grained duplication in EDDI

EOF
                        exit 0
                        ;;
                    -v | --verbose)
                        verbose=true;
                        ;;
                    -o*)
                        if [[ ${#opt} -eq 2 ]]; then
                            parse_state=1;
                        else
                            output_file=${opt##"-o"};
                        fi;
                        ;;
                    --llvm-bin*)
                        if [[ ${#opt} -eq 10 ]]; then
                            parse_state=3;
                        else
                            llvm_bin=${opt##"--llvm-bin="};
                        fi;
                        ;;
                    --cuda-bin*)
                        if [[ ${#opt} -eq 10 ]]; then   
                            parse_state=8;
                        else
                            cuda_bin=${opt##"--cuda-bin="};
                        fi;
                        ;;
                    --gpu-arch*)
                        if [[ ${#opt} -eq 10 ]]; then 
                            parse_state=9; 
                        else 
                            gpu_arch=${opt##"--gpu-arch="}; 
                        fi;
                        ;;
                    --suffix*)
                        if [[ ${#opt} -eq 8 ]]; then
                            parse_state=7;
                        else
                            suffix='-';
                            suffix+=${opt##"--suffix="};
                        fi;
                        ;;
                    --exclude*)
                        if [[ ${#opt} -eq 9 ]]; then
                            parse_state=4;
                        else
                            exclude_file=`echo "$opt" | cut -b 9`;
                        fi;
                        ;;
                    --asmfiles*)
                        if [[ ${#opt} -eq 10 ]]; then
                            parse_state=5;
                        else
                            asm_file=`echo "$opt" | cut -b 10`;
                        fi;
                        ;;
                    --build-dir*)
                        if [[ ${#opt} -eq 11 ]]; then
                            parse_state=6;
                        else
                            build_dir=`echo "$opt" | cut -b 10`;
                        fi;
                        ;;
                    --eddi)
                        dup=0
                        ;;
                    --reddi)
                        dup=3
                        ;;
                    --seddi)
                        dup=1
                        ;;
                    --fdsc)
                        dup=2
                        ;;
                    --no-dup)
                        dup=-1
                        ;;
                    --cfcss)
                        cfc=0
                        ;;
                    --rasm)
                        cfc=1
                        ;;
                    --inter-rasm)
                        cfc=2
                        ;;
                    --racfed)
                        cfc=3
                        ;;
                    --no-cfc)
                        cfc=-1
                        ;;
                    --alternate-memmap)
                        eddi_options="$eddi_options $opt=true";
                        ;;
                    --enable-profiling)
                        eddi_options="$eddi_options $opt=true";
                        cfc_options="$cfc_options $opt=true";
                        enable_profiling=true;
                        ;;                    
                    --multiple-errbb)
                        eddi_options="$eddi_options -multiple-errbb=true";
                        ;;
                    --coarse-grained)
                        eddi_options="$eddi_options -coarse-grained=true";
                        ;;
                    -g)
                        debug_enabled=true;
                        clang_options="$clang_options $opt";
                        eddi_options="$eddi_options --debug-enabled=true";
                        ;;
                    --no-cleanup)
                        cleanup=false;
                        ;;
                    -lstdc++)   
                        libstdcpp_added=true
                        ;;
                    *.c | *.cpp | *.cu)
                        input_files="$input_files $opt";
                        if [[ "$opt" == *.cu ]]; then
                            cuda_mode=true;
                        fi
                        # Check if it's a .cpp file and if -lstdc++ hasn't been added yet
                        if [[ "$opt" == *.cpp || "$opt" == *.cu ]] && [[ "$libstdcpp_added" == false ]]; then
                            clang_options="$clang_options -lstdc++"
                            libstdcpp_added=true 
                        fi
                        
                        ;;
                    *)
                        clang_options="$clang_options $opt";
                        ;;
                esac;
                ;;
            1)
                output_file="$opt";
                parse_state=0;
                ;;
            2)
                config_file="$opt";
                parse_state=0;
                ;;
            3)
                llvm_bin="$opt";
                parse_state=0;
                ;;
            4)
                exclude_file="$opt";
                parse_state=0;
                ;;
            5)
                asm_file="$opt";
                parse_state=0;
                ;;
            6) 
                build_dir="$opt";
                parse_state=0;
                ;;
            7)
                suffix="-$opt";
                parse_state=0;
                ;;
            8)
                cuda_bin="$opt"
                parse_state=0;
                ;;
            9)  gpu_arch="$opt";
                parse_state=0;
                ;;
      esac
    done

    if [[ $verbose == true ]]; then
        echo "Verbose mode ON"
        # Function to display commands
        exe() { 
            echo -e "\t\$ $@"
            "$@"
            local status=$?
            if [[ $status -ne 0 ]]; then
                error_msg "Command FAILED: $@"
            fi
        }
    else
        exe() { 
            "$@"
            local status=$?
            if [[ $status -ne 0 ]]; then
                error_msg "Command FAILED: $@"
            fi 
        }
    fi

    CLANG="${llvm_bin}/clang${suffix}" 
    OPT="${llvm_bin}/opt${suffix}"
    LLVM_LINK="${llvm_bin}/llvm-link${suffix}"
    LLC="${llvm_bin}/llc${suffix}"
    NVCC="${cuda_bin}/nvcc"

    if [[ -n "$config_file" ]]; then
        CLANG="${CLANG} --config ${config_file}"
    fi;
}

run_aspis() {
    if [[ -z ${input_files} ]]; then
        error_msg "No input files provided."
    fi

    exe mkdir -p $build_dir
    exe rm -f $build_dir/*.ll

    title_msg "Front-end and pre-processing"

    ## FRONTEND
    for input_file in $input_files; do
        # Extract the filename without extension
        filename=$(basename "$input_file" | sed 's/\.[^.]*$//')
        # Compile the file to LLVM IR (.ll) and save it in the build directory
        exe $CLANG "$input_file" $clang_options -S -emit-llvm -O0 -Xclang -disable-O0-optnone -o "$build_dir/$filename.ll"
    done

    ## LINK & PREPROCESS
    exe $LLVM_LINK $build_dir/*.ll -o $build_dir/out.ll

    success_msg "Emitted and linked IR."

    if [[ $debug_enabled == false ]]; then
        exe $OPT --passes="strip" $build_dir/out.ll -o $build_dir/out.ll
        echo "  Debug mode disabled, stripped debug symbols."
    fi
    
    exe $OPT --passes="lower-switch" $build_dir/out.ll -o $build_dir/out.ll

    ## FuncRetToRef
    if [[ dup -ne -1 ]]; then
        exe $OPT -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="func-ret-to-ref" $build_dir/out.ll -o $build_dir/out.ll
    fi;

    title_msg "ASPIS transformations"
    ## DATA PROTECTION
    case $dup in
        0) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="eddi-verify" $build_dir/out.ll -o $build_dir/out.ll $eddi_options
            ;;
        1) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libSEDDI.so --passes="eddi-verify" $build_dir/out.ll -o $build_dir/out.ll $eddi_options
            ;;
        2) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libFDSC.so --passes="eddi-verify" $build_dir/out.ll -o $build_dir/out.ll $eddi_options
            ;;
        3)
            exe $OPT -load-pass-plugin=$DIR/build/passes/libREDDI.so --passes="eddi-verify" $build_dir/out.ll -o $build_dir/out.ll $eddi_options
            ;;
        *)
            echo -e "\t--no-dup specified!"
    esac
    success_msg "Applied data protection passes."

    exe $OPT --passes="simplifycfg" $build_dir/out.ll -o $build_dir/out.ll

    ## CONTROL-FLOW CHECKING
    case $cfc in
        0) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libCFCSS.so --passes="cfcss-verify" $build_dir/out.ll -o $build_dir/out.ll $cfc_options
            ;;
        1) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libRASM.so --passes="rasm-verify" $build_dir/out.ll -o $build_dir/out.ll $cfc_options
            ;;
        2) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libINTER_RASM.so --passes="rasm-verify" $build_dir/out.ll -o $build_dir/out.ll $cfc_options
            ;;
        3)
            exe $OPT -load-pass-plugin=$DIR/build/passes/libRACFED.so --passes="racfed-verify" $build_dir/out.ll -o $build_dir/out.ll $cfc_options
            ;;
        *)
            echo -e "\t--no-cfc specified!"
    esac
    success_msg "Applied CFC passes."

    if [[ -n "$exclude_file" ]]; then
        # scan the directories of excluded files
        while IFS= read -r line 
        do
        excluded_files="${excluded_files} ${line}"
        done < "$exclude_file";

        ## Frontend & linking
        exe mv $build_dir/out.ll $build_dir/out.ll.bak
        exe rm $build_dir/*.ll
        exe mv $build_dir/out.ll.bak $build_dir/out.ll
        for input_file in $excluded_files; do
            # Extract the filename without extension
            filename=$(basename "$input_file" | sed 's/\.[^.]*$//')
            # Compile the file to LLVM IR (.ll) and save it in the build directory
            exe $CLANG "$input_file" $clang_options -S -emit-llvm -Xclang -disable-O0-optnone -o "$build_dir/$filename.ll"
        done
        exe $LLVM_LINK $build_dir/*.ll -o $build_dir/out.ll
    fi;
    success_msg "Linked excluded files to the compilation."

    ## DuplicateGlobals
    if [[ dup -ne -1 ]]; then
        exe $OPT -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="duplicate-globals" $build_dir/out.ll -o $build_dir/out.ll -S $eddi_options
        success_msg "Duplicated globals."
    fi;

    title_msg "Back-end"
    if [[ -n "$asm_file" ]]; then
        # scan the directories of excluded files
        while IFS= read -r line 
        do
        asm_files="${asm_files} ${line}"
        done < "$asm_file";
    fi;

    ## Backend
    exe $OPT $build_dir/out.ll -o $build_dir/out.ll -S $opt_flags
    if [[ "$enable_profiling" == "true" ]]; then
        title_msg "ASPIS Profiling"
        exe $OPT -load-pass-plugin=$DIR/build/passes/libPROFILER.so --passes="aspis-insert-check-profile" $build_dir/out.ll -o $build_dir/out.ll -S
        success_msg "Code instrumented."

        exe $CLANG $clang_options $build_dir/out.ll $asm_files -o $build_dir/$output_file 
        success_msg "Instrumented binary emitted."

        exe $build_dir/$output_file
        success_msg "Profiled code executed."

        echo -e "Analyzing..."
        exe $OPT -load-pass-plugin=$DIR/build/passes/libPROFILER.so --passes="aspis-check-profile" $build_dir/out.ll -o $build_dir/out.ll -S
        exit
    fi;

    case $output_file in 
        *.ll)
            exe cp $build_dir/out.ll $build_dir/$output_file.bak
            ;;
        *)
            exe $CLANG $clang_options $build_dir/out.ll $asm_files -o $build_dir/$output_file 
            ;;
    esac
    success_msg "Binary emitted."

    #Cleanup
    if [[ $cleanup == true ]]; then
        rm -f $build_dir/*.ll
        success_msg "Cleaned cached files."
    fi

    case $output_file in 
        *.ll)
            exe mv $build_dir/$output_file.bak $build_dir/$output_file
            ;;
    esac

    success_msg "Done!"
}

run_aspis_cuda() {
    # Check if nvcc exists, otherwise try to find it in PATH
    if [[ ! -x "$NVCC" ]]; then
        if which nvcc >/dev/null 2>&1; then
            NVCC="nvcc"
        else
            error_msg "nvcc not found. Please ensure CUDA is installed and in your PATH, or specify --cuda-bin."
        fi
    fi

    if [[ -z "$cuda_bin" && "$NVCC" == "nvcc" ]]; then
        cuda_bin=$(dirname "$(which nvcc)")
    fi
    local cuda_home=$(dirname "$cuda_bin") 

    if [[ ! -f "$LLC" ]]; then
        error_msg "Command llc not found. Expected path: ${LLC}. Please check --llvm-bin parameter."
    fi

    clang_options="$clang_options -I${cuda_home}/include"
    if [[ -n "$cuspis_path" ]]; then
        clang_options="$clang_options -I$cuspis_path"
    fi

    if [[ -z ${input_files} ]]; then
        error_msg "No input files provided."
    fi

    exe mkdir -p $build_dir
    exe rm -f $build_dir/*.ll

    title_msg "Compiling Device Code to IR"

    device_ir_files=""
    for input_file in $input_files; do
        filename=$(basename "$input_file" | sed 's/\.[^.]*$//')
        exe $CLANG $clang_options -x cuda --cuda-path="$cuda_home" --cuda-gpu-arch=$gpu_arch --cuda-device-only -emit-llvm -S "$input_file" -o "$build_dir/${filename}_device.ll" -O0 -Xclang -disable-O0-optnone
        device_ir_files="$device_ir_files $build_dir/${filename}_device.ll"
    done

    exe $LLVM_LINK $device_ir_files -o $build_dir/device_linked.ll

    if [[ $debug_enabled == false ]]; then
        exe $OPT --passes="strip" $build_dir/device_linked.ll -o $build_dir/device_linked.ll
        echo "  Debug mode disabled, stripped debug symbols."
    fi

    title_msg "Applying ASPIS Passes to Device Code"

    exe $OPT --passes="lower-switch" $build_dir/device_linked.ll -o $build_dir/device_linked.ll

    ## FuncRetToRef
    if [[ dup -ne -1 ]]; then
        exe $OPT -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="func-ret-to-ref" $build_dir/device_linked.ll -o $build_dir/device_linked.ll
    fi;

    title_msg "Device-side ASPIS transformations"
    ## DATA PROTECTION
    case $dup in
        0) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="eddi-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $eddi_options
            ;;
        1) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libSEDDI.so --passes="eddi-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $eddi_options
            ;;
        2) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libFDSC.so --passes="eddi-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $eddi_options
            ;;
        3)
            exe $OPT -load-pass-plugin=$DIR/build/passes/libREDDI.so --passes="eddi-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $eddi_options
            ;;
        *)
            echo -e "\t--no-dup specified!"
    esac
    success_msg "Applied device-side data protection passes."

    exe $OPT --passes="simplifycfg" $build_dir/device_linked.ll -o $build_dir/device_linked.ll

    title_msg "Device-side CFC"
    ## CONTROL-FLOW CHECKING
    case $cfc in
        0) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libCFCSS.so --passes="cfcss-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $cfc_options
            ;;
        1) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libRASM.so --passes="rasm-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $cfc_options
            ;;
        2) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libINTER_RASM.so --passes="rasm-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $cfc_options
            ;;
        3)
            exe $OPT -load-pass-plugin=$DIR/build/passes/libRACFED.so --passes="racfed-verify" $build_dir/device_linked.ll -o $build_dir/device_linked.ll $cfc_options
            ;;
        *)
            echo -e "\t--no-cfc specified!"
    esac
    success_msg "Applied device-side CFC passes."

    ## DuplicateGlobals
    if [[ dup -ne -1 ]]; then
        exe $OPT -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="duplicate-globals" $build_dir/device_linked.ll -o $build_dir/device_linked.ll -S $eddi_options
        success_msg "Duplicated globals."
    fi;

    title_msg "Compiling Device IR to PTX and Fatbinary"

    exe $LLC -march=nvptx64 -mcpu=$gpu_arch $build_dir/device_linked.ll -o $build_dir/device.ptx

    exe $NVCC -fatbin -arch=$gpu_arch $build_dir/device.ptx -o $build_dir/device.fatbin


    title_msg "Compiling Host Code to IR"

    host_objects=""
    for input_file in $input_files; do
        filename=$(basename "$input_file" | sed 's/\.[^.]*$//')
        exe $CLANG $clang_options -x cuda --cuda-path="$cuda_home" --cuda-host-only --cuda-gpu-arch=$gpu_arch -Xclang -fcuda-include-gpubinary -emit-llvm -S -Xclang $build_dir/device.fatbin -c "$input_file" -o "$build_dir/${filename}_host.ll"
        host_objects="$host_objects $build_dir/${filename}_host.ll"
    done
    
    exe $LLVM_LINK $host_objects -o $build_dir/host_linked.ll

    if [[ $debug_enabled == false ]]; then
        exe $OPT --passes="strip" $build_dir/host_linked.ll -o $build_dir/host_linked.ll
        echo "  Debug mode disabled, stripped debug symbols."
    fi 

    title_msg "Applying ASPIS passes to Host Code"
    
    exe $OPT --passes="lower-switch" $build_dir/host_linked.ll -o $build_dir/host_linked.ll

    ## FuncRetToRef
    if [[ dup -ne -1 ]]; then
        exe $OPT -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="func-ret-to-ref" $build_dir/host_linked.ll -o $build_dir/host_linked.ll
    fi;

    title_msg "Host-side ASPIS transformations"
    ## DATA PROTECTION
    case $dup in
        0) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="eddi-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $eddi_options
            ;;
        1) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libSEDDI.so --passes="eddi-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $eddi_options
            ;;
        2) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libFDSC.so --passes="eddi-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $eddi_options
            ;;
        3)
            exe $OPT -load-pass-plugin=$DIR/build/passes/libREDDI.so --passes="eddi-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $eddi_options
            ;;
        *)
            echo -e "\t--no-dup specified!"
    esac
    success_msg "Applied host-side data protection passes."

    exe $OPT --passes="simplifycfg" $build_dir/host_linked.ll -o $build_dir/host_linked.ll

    title_msg "Host-side CFC"
    ## CONTROL-FLOW CHECKING
    case $cfc in
        0) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libCFCSS.so --passes="cfcss-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $cfc_options
            ;;
        1) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libRASM.so --passes="rasm-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $cfc_options
            ;;
        2) 
            exe $OPT -load-pass-plugin=$DIR/build/passes/libINTER_RASM.so --passes="rasm-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $cfc_options
            ;;
        3)
            exe $OPT -load-pass-plugin=$DIR/build/passes/libRACFED.so --passes="racfed-verify" $build_dir/host_linked.ll -o $build_dir/host_linked.ll $cfc_options
            ;;
        *)
            echo -e "\t--no-cfc specified!"
    esac
    success_msg "Applied host-side CFC passes."

    ## DuplicateGlobals
    if [[ dup -ne -1 ]]; then
        exe $OPT -load-pass-plugin=$DIR/build/passes/libEDDI.so --passes="duplicate-globals" $build_dir/host_linked.ll -o $build_dir/host_linked.ll -S $eddi_options
        success_msg "Duplicated globals."
    fi;

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
}

parse_commands "$@"
perform_platform_checks $CLANG $OPT $LLVM_LINK
if [[ $cuda_mode == true ]]; then  
    run_aspis_cuda
else
    run_aspis
fi
