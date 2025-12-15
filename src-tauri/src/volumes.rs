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
    let mut disks = Disks::new_with_refreshed_list();
    disks.refresh();

    let mut seen_mount_points = std::collections::HashSet::new();
    let volumes: Vec<VolumeInfo> = disks
        .iter()
        .filter_map(|disk| {
            let mount_point = disk.mount_point().to_string_lossy().to_string();

            // Skip duplicates based on mount point
            if seen_mount_points.contains(&mount_point) {
                return None;
            }
            seen_mount_points.insert(mount_point.clone());

            Some(VolumeInfo {
                name: disk.name().to_string_lossy().to_string(),
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
