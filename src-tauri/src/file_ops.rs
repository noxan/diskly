use std::path::Path;
use std::process::Command;

#[tauri::command]
pub async fn file_preview(_path: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        Command::new("qlmanage")
            .args(["-p", &_path])
            .spawn()
            .map_err(|e| format!("Failed to preview file: {}", e))?;
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err("Preview is only supported on macOS".to_string())
    }
}

#[tauri::command]
pub async fn file_open(path: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        Command::new("open")
            .args(["-R", &path])
            .spawn()
            .map_err(|e| format!("Failed to open in Finder: {}", e))?;
        Ok(())
    }
    #[cfg(target_os = "windows")]
    {
        Command::new("explorer")
            .args(["/select,", &path])
            .spawn()
            .map_err(|e| format!("Failed to open in Explorer: {}", e))?;
        Ok(())
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        let parent = Path::new(&path)
            .parent()
            .ok_or("Failed to get parent directory")?;
        Command::new("xdg-open")
            .arg(parent)
            .spawn()
            .map_err(|e| format!("Failed to open file manager: {}", e))?;
        Ok(())
    }
}

#[tauri::command]
pub async fn file_delete(path: String) -> Result<(), String> {
    trash::delete(&path).map_err(|e| format!("Failed to move to trash: {}", e))
}
