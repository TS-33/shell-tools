#!/bin/bash

for i in *
do
	if [[ $i != "install.sh" ]]
	then
		cp $i /bin <<EOF &> /dev/null
y
EOF
	fi
done
