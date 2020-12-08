#!/bin/bash
#creamos grupo para limitar recursos y evitar overflow
cgcreate -g memory:RAMlimitada
#definimos la limitacion de ram en este caso 2 GB
cgset -r memory.limit_in_bytes=$((2*1024*1024*1024)) RAMlimitada
#Actualizamos la lista de paquetes
apt update
#listamos los paquetes a actualizar sin añadidos detras del nombre del paquete y meterlos en el array  grep -v "^Listing" |
paquetes=($(apt list --upgradable 2>/dev/null | cut -d'/' -f1))
#Eliminamos la primera posicion del array ya que contiene el listando en el idioma del sistema
unset 'paquetes[0]'
#vamos paquete por paquete instalando
for i in "${paquetes[@]}"
do
		echo -e "\e[93mActualizando con apt-build el paquete ""${i}"
		cgexec -g memory:RAMlimitada apt-build install "${i}"
        echo -e "\e[93mIntentado o instalado paquete con apt-build"
        echo "-------------------------------------------------------------------"
        echo -e "\e[34mActualizando paquete ""${i}"" con apt"
        apt install "${i}"
        echo -e "\e[34mPaquete actualizado"
done
