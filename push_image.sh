#!/bin/sh
set -e

usage='这个脚本用于运行docker build命令，
基于当前目录下Dockerfile的image，并将生成的image推送到给定的节点，
最后在节点上执行nerdctl -n k8s.io load <image> 命令，导入镜像。
'
PASSWD='huawei@123'

echo $usage
echo 默认密码: $PASSWD
echo

read -e -p "Input image's tag: " TAG
read -e -p "Input target nodes: (like node1 node2) " NODES

if [[ -z $TAG ]];then
	echo Input can\'t be NULL!!
	exit
fi

if [[ ! -f Dockerfile ]];then
	echo Didn\'t find a Dockerfile here!!
	exit
fi

IMAGE_NAME=$(grep FROM Dockerfile | awk '{print $2}' | cut -d ':' -f 1)

if [[ -f ${IMAGE_NAME}_${TAG}.tar ]];then
    echo find ${IMAGE_NAME}_${TAG}.tar, I\'ll push this file directly...
else
	echo building image...
	echo 
	docker build -t ${IMAGE_NAME}:${TAG} .
	docker save ${IMAGE_NAME}:${TAG} -o ${IMAGE_NAME}_${TAG}.tar
fi


for i in ${NODES};do
sshpass -p $PASSWD scp ${IMAGE_NAME}_${TAG}.tar $i:/tmp
sshpass -p $PASSWD ssh $i "nerdctl -n k8s.io load -i /tmp/${IMAGE_NAME}_${TAG}.tar"
done


