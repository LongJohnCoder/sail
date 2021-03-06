#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd $DIR/..

printf "******************************************\n"
printf "* Typechecking tests                     *\n"
printf "******************************************\n\n"

./test/typecheck/run_tests.sh

printf "******************************************\n"
printf "* Ocaml tests                            *\n"
printf "******************************************\n\n"

./test/ocaml/run_tests.sh

printf "******************************************\n"
printf "* C tests                                *\n"
printf "******************************************\n\n"

./test/c/run_tests.sh

printf "******************************************\n"
printf "* Lem tests                              *\n"
printf "******************************************\n\n"

./test/lem/run_tests.sh

printf "******************************************\n"
printf "* ARM spec tests                         *\n"
printf "******************************************\n\n"

./test/arm/run_tests.sh

printf "******************************************\n"
printf "* RISCV spec tests                       *\n"
printf "******************************************\n\n"

./test/riscv/run_tests.sh

printf "******************************************\n"
printf "* CHERI spec tests                       *\n"
printf "******************************************\n\n"

./test/cheri/run_tests.sh
