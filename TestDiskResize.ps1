# Принимаем параметры для скрипта

param(
    # Размер создаваемого EFI-раздела, по умолчанию 10 GB
    [int]$EfiSizeGB = 10,

    # Минимальный размер неразмеченного места после сжатия, по умолчанию 20 GB
    [int]$MinUnallocatedGB = 20,

    # Включить запись логов в файл
    [switch]$EnableLog,

    # Путь к файлу лога
    [string]$LogFile
)

# Изменяем обработку ошибок для корректной работы try\catch

$ErrorActionPreference = "Stop"

# Обрабатываем ошибки через функцию

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Text = "[{0}] [{1}] {2}" -f `
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),
        $Level,
        $Message

    Write-Host $Text

    if ($EnableLog -and $LogFile) {
        Add-Content -Path $LogFile -Value $Text
    }
}

try {
    Write-Log "Запуск скрипта."

    # Переводим параметры из GB в байты
    $EfiSize = $EfiSizeGB * 1GB
    $MinUnallocatedSize = $MinUnallocatedGB * 1GB

    # Определяем системный раздел Windows
    $SystemDriveLetter = $env:SystemDrive.TrimEnd(":")
    $SystemPartition = Get-Partition | Where-Object DriveLetter -eq $SystemDriveLetter

    Write-Log "Определен системный раздел: $SystemDriveLetter`:"

    # Определяем диск, на котором находится системный раздел
    $DiskNumber = $SystemPartition.DiskNumber

    Write-Log "Системный раздел находится на диске номер $DiskNumber."

    # Запоминаем исходный размер системного раздела для отката
    $OldSystemSize = $SystemPartition.Size

    Write-Log "Исходный размер системного раздела: $([math]::Round($OldSystemSize / 1GB, 2)) GB."

    # Получаем минимально возможный размер системного раздела

    $SupportedSize = Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $SystemPartition.PartitionNumber

    Write-Log "Минимально возможный размер системного раздела: $([math]::Round($SupportedSize.SizeMin / 1GB, 2)) GB."

    # Сжимаем системный раздел на максимально возможное пространство

    Write-Log "Выполняется максимальное сжатие системного раздела."

    Resize-Partition -DiskNumber $DiskNumber -PartitionNumber $SystemPartition.PartitionNumber -Size $SupportedSize.SizeMin

    Write-Log "Системный раздел сжат."

    # Проверяем получившееся неразмеченное место

    $Disk = Get-Disk -Number $DiskNumber
    $UnallocatedSize = $Disk.LargestFreeExtent

    Write-Log "Размер полученного неразмеченного места: $([math]::Round($UnallocatedSize / 1GB, 2)) GB."

     # Проверяем что полученное место соответствует переменной MinUnallocatedGB

    if ($UnallocatedSize -lt $MinUnallocatedSize) {
        # При несоотествии прекращаем выполение и производим откат
        throw "Неразмеченного места меньше требуемого значения $MinUnallocatedGB GB."
    }

    Write-Log "Неразмеченного места достаточно."

    # Создаем EFI-раздел в конце диска
    Write-Log "Создается EFI-раздел размером $EfiSizeGB GB."

    $EfiPartition = New-Partition -DiskNumber $DiskNumber -Size $EfiSize -AssignDriveLetter

    Write-Log "EFI-раздел создан."

    # Форматируем EFI-раздел в FAT32
    Write-Log "Форматирование EFI-раздела в FAT32."

    Format-Volume -DriveLetter $EfiPartition.DriveLetter -FileSystem FAT32 -NewFileSystemLabel "EFI" -Confirm:$false

    Write-Log "EFI-раздел отформатирован."

    # Назначаем разделу тип EFI System Partition
    Write-Log "Назначение GUID типа EFI System Partition."

    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $EfiPartition.PartitionNumber -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"

    Write-Log "Тип раздела EFI назначен."

    # Копируем загрузочные файлы Windows на EFI-раздел
    Write-Log "Копирование загрузочных файлов Windows на EFI-раздел."

    bcdboot "$env:SystemRoot" /s "$($EfiPartition.DriveLetter):" /f UEFI

    Write-Log "Загрузочные файлы скопированы."

    # Убираем букву диска у EFI-раздела
    Write-Log "Удаление буквы диска у EFI-раздела."

    Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $EfiPartition.PartitionNumber -AccessPath "$($EfiPartition.DriveLetter):\"

    Write-Log "Буква диска удалена."

    Write-Log "Операция выполнена успешно."
    exit 0
}
catch {
    Write-Log "Ошибка выполнения: $($_.Exception.Message)" "ERROR"
    Write-Log "Запущен откат изменений." "WARNING"

    try {
        # Если EFI-раздел был создан — удаляем его
        if ($EfiPartition) {
            Write-Log "Удаление созданного EFI-раздела." "WARNING"

            Remove-Partition -DiskNumber $DiskNumber -PartitionNumber $EfiPartition.PartitionNumber -Confirm:$false

            Write-Log "EFI-раздел удален." "WARNING"
        }

        # Возвращаем системный раздел к исходному размеру
        if ($OldSystemSize) {
            Write-Log "Возврат системного раздела к исходному размеру." "WARNING"

            Resize-Partition -DiskNumber $DiskNumber -PartitionNumber $SystemPartition.PartitionNumber -Size $OldSystemSize

            Write-Log "Системный раздел восстановлен." "WARNING"
        }

        Write-Log "Откат завершен." "WARNING"
    }
    catch {
        Write-Log "Ошибка при откате: $($_.Exception.Message)" "ERROR"
    }

    exit 1
}