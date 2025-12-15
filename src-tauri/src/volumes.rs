use sysinfo::Disks;

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VolumeInfo {
    pub name: String,
    pub mount_point: String,
    pub total_space: u64,
    pub available_space: u64,
    pub file_system: String,
    pub is_removable: bool,
}

#[tauri::command]
pub async fn list_volumes() -> Result<Vec<VolumeInfo>, String> {
    let disks = Disks::new_with_refreshed_list();

    let mut seen_names: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    let volumes: Vec<VolumeInfo> = disks
        .iter()
        .filter_map(|disk| {
            let mount_point = disk.mount_point().to_string_lossy().to_string();
            let name = disk.name().to_string_lossy().to_string();

            // Skip macOS data volume if we have root mounted
            if mount_point.starts_with("/System/Volumes/Data") {
                return None;
            }

            // Skip duplicates based on disk name, preferring shorter mount points
            if let Some(existing_mount) = seen_names.get(&name) {
                if mount_point.len() >= existing_mount.len() {
                    return None;
                }
            }
            seen_names.insert(name.clone(), mount_point.clone());

            Some(VolumeInfo {
                name,
                mount_point,
                total_space: disk.total_space(),
                available_space: disk.available_space(),
                file_system: disk.file_system().to_string_lossy().to_string(),
                is_removable: disk.is_removable(),
            })
        })
        .collect();

    Ok(volumes)
}
