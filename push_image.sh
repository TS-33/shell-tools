#!/bin/sh
set -e

usage='这个脚本用于运行docker build命令，生成一个基于当前目录下Dockerfile的image，并将生成的image推送到192.168.36.160、161、162节点，然后在节点上执行nerdctl -n k8s.io load <image> 命令，导入镜像。
'

echo $usage
echo 
echo

echo -n "Please input image's tag: "
read TAG

if [[ -z $TAG ]];then
	echo Input can\'t be NULL!!
	exit
fi

if [[ ! -f Dockerfile ]];then
	echo Didn\'t find a Dockerfile here!!
	exit
fi

IMAGE_NAME=$(grep FROM Dockerfile | awk '{print $2}' | cut -d ':' -f 1)

docker build -t ${IMAGE_NAME}:${TAG} .
docker save ${IMAGE_NAME}:${TAG} -o ${IMAGE_NAME}_${TAG}.tar

for i in 160 161 162;do
scp ${IMAGE_NAME}_${TAG}.tar 192.168.36.$i:/tmp
ssh 192.168.36.$i "nerdctl -n k8s.io load -i /tmp/${IMAGE_NAME}_${TAG}.tar"
done


