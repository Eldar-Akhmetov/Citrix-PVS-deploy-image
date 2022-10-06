# Citrix-PVS-deploy-image
- [Описание](#описание)
- [Требования](#требования)
- [Предварительная настройка](#настройка)
- [Запуск скрипта](#запуск)
- [Логирование](#логирование)
- [Классы объектов](#классы)


## Описание <a name="описание"></a>

Данный скрипт предназначен для автоматизации процесса тиражирования образов Citrix PVS на виртуальные машины.
Скрипт написан для инфраструктуры с 2-мя ЦОД, количество серверов в каждом ЦОД не важно.
Его необходимо запускать на сервере PVS к которому привязаны образы в режиме правки.
Каждый образ привязывается ко всем виртуальным машинам нужной коллекции или нескольким коллекциям.
> **Warning**  
> Если у вас в одной коллекции к виртуальным машинам привязываются разные образы, то необходимо разделение этих машин на разные коллекции!!!

Скрипт загружает данные из заранее подготовленного файла "Setting.xml", далее подключается к локальному серверу PVS при помощи модуля "Citrix.PVS.SnapIn".
1) Скрипт предлагает ввести имена VM с подключенными образами для упаковки и тиражирования вручную или он сам получит имена машин из device collection с виртуальными машинами для внесения изменений.
2) Если виртуальная машина выключена или образ подключенный к ней в стандартом режиме он пропускает ее. Если она включена и подключенный образ в режиме правки, то через Invoke-Command (PowerShell Remoting) создает задания (jobs). В данных заданиях на виртуальных машинах запускается скрипт для удаления сертификатов SCOM и SCCM, кэш SCCM, удаляется ключ в реестре 120-ти дневного льготного периода RDS и сохраненные профиля пользователей кроме системных и текущего пользователя. Так же он останавливает и отключает службу Windows Update, выключает виртуальную машину.
3) Дождавшись, что виртуальные машины выключены он меняет режим диска на стандартный с записью кэша в оперативную память и на диск, размер кэша устанавливается 4096 МБ. Если образы заблокированы одной виртуальной машиной то предполагается, что это виртуальная машина для изменения образа или тестовая машина и блокировка снимается. Если образ заблокирован большим числом виртуальных машин, то образ пропускается и выводится соответствующее сообщение с именами машин.
5) Далее выполняется копирование образов на все PVS серверы при помощи Robocopy, для каждого сервера PVS создается отдельный системный процесс для параллельного копирования, но каждый образ копируется последовательно, чтобы процессы не утилизировали все ресурсы ОЗУ, CPU и для снижения нагрузки на сеть.
6) После копирования образов они добавляются в хранилище образов PVS во 2-ом ЦОД.
7) Выполняется привязка образов к device dollections согласно ассоциации коллекций устройств с хранилищами образов в файле "Setting.xml". 

## Требования <a name="требования"></a>
- Windows Server (2012 r2+)
- Powershell (5.1+)
- Модуль Powershell "Citrix.PVS.SnapIn" (устанавливается вместе с Provisioning Services Console).  
Можно импортировать отдельно, в скрипте путь к модулю указан по умолчанию "C:\Program Files\Citrix\Provisioning Services Console\Citrix.PVS.SnapIn.dll", в файле Citrix-PVS-deploy-image.ps1

## Запуск скипта <a name="запуск"></a>

1) Клонировать проект на PVS сервер к которому привязаны образы в private режиме.  

По HTTPS ссылке: 
```
git clone https://github.com/Eldar-Akhmetov/Citrix-PVS-deploy-image.git
```
По SSH ссылке:
```
git clone git@github.com:Eldar-Akhmetov/Citrix-PVS-deploy-image.git
```
Или скачать ZIP архив: [Citrix-PVS-deploy-image.zip](https://github.com/Eldar-Akhmetov/Citrix-PVS-deploy-image/archive/refs/heads/main.zip)  

2) Заполнить необходимые данные в [Setting.xml](https://github.com/Eldar-Akhmetov/Citrix-PVS-deploy-image/blob/main/Setting.xml)  
3) Выполнить файл [Citrix-PVS-deploy-image.ps1](https://github.com/Eldar-Akhmetov/Citrix-PVS-deploy-image/blob/main/Citrix-PVS-deploy-image.ps1)

## Предварительная настройка <a name="настройка"></a>
Перед началом работы, необходимо заполнить теги в файле конфигурации [Setting.xml](https://github.com/Eldar-Akhmetov/Citrix-PVS-deploy-image/blob/main/Setting.xml):
#### 1) Тег \<Associated_Stores> - ассоциации Store и Device Collection, образ из данного хранилища будет привязан ко всем виртуальным машинам в указанной коллекции машин.
Тег \<Associated_Stores> содержит под теги \<Store> - имя store, образ которого будет привязан к вирткальным машинам и \<DeviceCollection> - имя коллекции виртуальных машин для привязки.

Пример заполнения для привязки образа из store с именем "Store-01" к виртуальным машинам из коллекции устройств "DeviceCollection-01":
```
<Associated_Stores>
      <Store>Store-01</Store>
      <DeviceCollection>DeviceCollection-01</DeviceCollection>
</Associated_Stores>
 ```
 
Если образ привязывается к нескольким коллекциям, просто перечислите их через запятую:
```
<DeviceCollection>DeviceCollection-01, DeviceCollection-02, DeviceCollection-03</DeviceCollection>
```
Для добавления новых ассоциаций просто скопируйте тег <Associated_Stores> </Associated_Stores> с под тегами и вставьте ниже текущего тега, далее измените Store Name и Device Collection Name.

   
#### 2) Тег \<Domain>, укажите имя домена вашей организации.

Пример для домена "test.org":
```
<Domain>test.org</Domain>
```
   
#### 3) Тег \<WR_DeviceCollection>, нужно указать имя Device Collection где расположены виртуальные машины для подключения образов в режиме правки (private).
Именно в этой коллекции будет выполнятся поиск образов в private режиме привязанных к виртуальным машинам в ней, для последующего тиражирования.

Пример с именем коллекции "DeviceCollection-Write":
```
<WR_DeviceCollection>DeviceCollection-Write</WR_DeviceCollection>
```
   
#### 4) Теги \<ServersPVS_COD1> и \<ServersPVS_COD2> в них нужно перечислить через запятую серверы PVS каждого ЦОД соответственно.

Пример для PVS серверов 1-го ЦОД "pvs-01, pvs-02, pvs-03" и 2-го ЦОД "pvs-21, pvs-22, pvs-23":
```
<ServersPVS_COD1>pvs-01, pvs-02, pvs-03</ServersPVS_COD1>
<ServersPVS_COD2>pvs-21, pvs-22, pvs-23</ServersPVS_COD2>
```
   
#### 5) Тег \<SiteName>, указывается имя сайта в ферме PVS, имя сайта можно посмотреть в консоли PVS.

Пример для сайта "Main":
```
<SiteName>Main</SiteName>
```

## Логирование <a name="логирование"></a>

Все действия скрипта и ошибки сохраняются в папке "logs".
Имена лог файлов в формате: "текущая дата-log.log".
Для изменения пути сохранения или формата имени лог файла измените глобальную переменную "$logfile" в файле "Citrix-PVS-deploy-image.ps1".
Запись логов выполняется функцией "LogWrite" в том же файле.

## Классы объектов
Файлы классов расположены в папке Classes.
На данный момент есть 2 класса объектов: DeviceWR и Image.

### Класс DeviceWR
Класс описывающий объект DeviceWR (виртуальную машину с подключенным диском в режиме private). В конструкторе принимает обязательные аргументы:
1) $deviceName - имя виртуальной машины.
2) $siteName - имя сайта в ферме PVS.

Переменная $image - это экземпляр класса Image, создается в конструкторе при инициализации экземпляра класса DeviceWR.

Все методы класса подробно описаны в одноименном файле класса.

### Класс Image <a name="классы"></a>
Класс описывающий объект Image (образ для тиражирования на виртуальные машины), в конструкторе принимает обязательные аргументы:
1) $imageName - имя образа, должно соответствовать имени vhdx файла образа.
2) $storeName - имя store где расположен образ.
3) $siteName - имя сайта в PVS ферме.
4) $deviceWR - имя виртуальной машины к которой подключен образ в режиме правки (private mode).
5) $serverProvisioning - имя PVS сервера с которого выполняется стриминг образа в приватном режиме, имя сервера будет получено при создании экземпляра класса, если для образа включен алгоритм балансировки нагрузки, значение будет равно $null.

Данные переменные заполняются автоматически при помощи методов и аргументов класса DeviceWR, так как экземпляр класса Image является полем класса DeviceWR.

Все методы класса подробно описаны в одноименном файле класса.
