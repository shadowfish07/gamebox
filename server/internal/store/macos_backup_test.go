package store

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

func TestMacOSBackupPreservesLiveWAL(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS deployment backup")
	}
	path := filepath.Join(t.TempDir(), "gamebox.sqlite")
	db, err := Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	insertCrossProcessUser(t, db, crossProcessOwnerID, "Owner", "owner")
	before := existingSidecarIdentities(t, path)
	backupDir := filepath.Join(t.TempDir(), "backups")
	cmd := exec.Command("/bin/zsh", "../../../deploy/macos/backup.sh")
	cmd.Env = append(os.Environ(), "GAMEBOX_DB_PATH="+path, "GAMEBOX_BACKUP_DIR="+backupDir)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("backup: %v\n%s", err, output)
	}
	after := existingSidecarIdentities(t, path)
	for suffix, original := range before {
		current, exists := after[suffix]
		if !exists || !os.SameFile(original, current) {
			t.Fatalf("backup removed or replaced live %s", suffix)
		}
	}
	// Force fresh pooled connections as well as reuse of the pre-backup one.
	for i := 0; i < maxConnections; i++ {
		conn, err := db.Conn(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		var count int
		if err := conn.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM users WHERE id=?`, crossProcessOwnerID).Scan(&count); err != nil || count != 1 {
			t.Fatalf("connection %d: count=%d err=%v", i, count, err)
		}
	}
	files, err := filepath.Glob(filepath.Join(backupDir, "gamebox-*.db"))
	if err != nil || len(files) != 1 {
		t.Fatalf("backup files=%v err=%v", files, err)
	}
	backup, err := OpenReadOnly(context.Background(), files[0])
	if err != nil {
		t.Fatal(err)
	}
	defer backup.Close()
	var count int
	if err := backup.QueryRow(`SELECT COUNT(*) FROM users WHERE id=?`, crossProcessOwnerID).Scan(&count); err != nil || count != 1 {
		t.Fatalf("backup count=%d err=%v", count, err)
	}
}
