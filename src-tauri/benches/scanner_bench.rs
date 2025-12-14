use criterion::{black_box, criterion_group, criterion_main, Criterion};
use diskly_lib::scanner::ScannerCore;
use std::fs;
use std::path::Path;
use tempfile::TempDir;

fn create_test_tree(
    base: &Path,
    files_per_dir: usize,
    depth: usize,
    current_depth: usize,
) -> usize {
    if current_depth >= depth {
        return 0;
    }

    let mut total_files = 0;

    // Create files in current directory
    for i in 0..files_per_dir {
        let file_path = base.join(format!("file_{}.txt", i));
        fs::write(&file_path, format!("test content {}", i)).unwrap();
        total_files += 1;
    }

    // Create subdirectories
    if current_depth < depth - 1 {
        for i in 0..files_per_dir {
            let subdir = base.join(format!("dir_{}", i));
            fs::create_dir_all(&subdir).unwrap();
            total_files += create_test_tree(&subdir, files_per_dir, depth, current_depth + 1);
        }
    }

    total_files
}

fn create_wide_flat_tree(base: &Path, file_count: usize) -> usize {
    for i in 0..file_count {
        let file_path = base.join(format!("file_{}.txt", i));
        fs::write(&file_path, format!("test content {}", i)).unwrap();
    }
    file_count
}

fn create_deep_narrow_tree(base: &Path, depth: usize) -> usize {
    let mut current = base.to_path_buf();
    for i in 0..depth {
        current = current.join(format!("level_{}", i));
        fs::create_dir_all(&current).unwrap();
        let file_path = current.join("file.txt");
        fs::write(&file_path, format!("test content at depth {}", i)).unwrap();
    }
    depth
}

fn bench_scanner(c: &mut Criterion) {
    let mut group = c.benchmark_group("scanner");
    group.sample_size(25);

    // Small directory: 100 files, 3 levels deep
    group.bench_function("small_100_files_3_levels", |b| {
        let temp_dir = TempDir::new().unwrap();
        let file_count = create_test_tree(temp_dir.path(), 5, 3, 0);

        b.iter(|| {
            let scanner = ScannerCore::new();
            let result = scanner.scan_directory(black_box(temp_dir.path()));
            assert!(result.is_ok());
            assert_eq!(scanner.get_total_scanned(), file_count as u64);
        });
    });

    // Medium directory: 1000 files, 5 levels deep
    group.bench_function("medium_1000_files_5_levels", |b| {
        let temp_dir = TempDir::new().unwrap();
        let file_count = create_test_tree(temp_dir.path(), 4, 5, 0);

        b.iter(|| {
            let scanner = ScannerCore::new();
            let result = scanner.scan_directory(black_box(temp_dir.path()));
            assert!(result.is_ok());
            assert_eq!(scanner.get_total_scanned(), file_count as u64);
        });
    });

    // Large directory: 10000 files, 7 levels deep
    group.bench_function("large_10000_files_7_levels", |b| {
        let temp_dir = TempDir::new().unwrap();
        let file_count = create_test_tree(temp_dir.path(), 3, 7, 0);

        b.iter(|| {
            let scanner = ScannerCore::new();
            let result = scanner.scan_directory(black_box(temp_dir.path()));
            assert!(result.is_ok());
            assert_eq!(scanner.get_total_scanned(), file_count as u64);
        });
    });

    // Wide flat directory: 5000 files in one directory
    group.bench_function("wide_flat_5000_files", |b| {
        let temp_dir = TempDir::new().unwrap();
        let file_count = create_wide_flat_tree(temp_dir.path(), 5000);

        b.iter(|| {
            let scanner = ScannerCore::new();
            let result = scanner.scan_directory(black_box(temp_dir.path()));
            assert!(result.is_ok());
            assert_eq!(scanner.get_total_scanned(), file_count as u64);
        });
    });

    // Deep narrow directory: 100 levels, 1 file each
    group.bench_function("deep_narrow_100_levels", |b| {
        let temp_dir = TempDir::new().unwrap();
        let file_count = create_deep_narrow_tree(temp_dir.path(), 100);

        b.iter(|| {
            let scanner = ScannerCore::new();
            let result = scanner.scan_directory(black_box(temp_dir.path()));
            assert!(result.is_ok());
            assert_eq!(scanner.get_total_scanned(), file_count as u64);
        });
    });

    group.finish();
}

criterion_group!(benches, bench_scanner);
criterion_main!(benches);


