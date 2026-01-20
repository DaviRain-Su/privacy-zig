use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Note {
    pub id: String,
    pub amount: u64,
    pub privkey: String,
    pub pubkey: String,
    pub blinding: String,
    pub commitment: String,
    pub leaf_index: i64,
    pub status: String,
    pub created_at: u64,
    pub deposit_tx_sig: Option<String>,
    pub withdraw_tx_sig: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Default)]
pub struct NoteStore {
    pub notes: Vec<Note>,
}

impl NoteStore {
    /// Get the default notes file path
    fn notes_path() -> Result<PathBuf> {
        let home = dirs::home_dir().ok_or_else(|| anyhow!("Could not find home directory"))?;
        let dir = home.join(".privacy-zig");
        
        if !dir.exists() {
            fs::create_dir_all(&dir)?;
        }
        
        Ok(dir.join("notes.json"))
    }

    /// Load notes from disk
    pub fn load() -> Result<Self> {
        let path = Self::notes_path()?;
        
        if !path.exists() {
            return Ok(Self::default());
        }
        
        let data = fs::read_to_string(&path)?;
        let store: NoteStore = serde_json::from_str(&data)?;
        Ok(store)
    }

    /// Save notes to disk
    pub fn save(&self) -> Result<()> {
        let path = Self::notes_path()?;
        let data = serde_json::to_string_pretty(self)?;
        fs::write(&path, data)?;
        Ok(())
    }

    /// Add a new note
    pub fn add(&mut self, note: Note) -> Result<()> {
        self.notes.push(note);
        self.save()
    }

    /// Update note status
    pub fn update_status(&mut self, id: &str, status: &str, tx_sig: Option<&str>) -> Result<bool> {
        if let Some(note) = self.notes.iter_mut().find(|n| n.id == id) {
            note.status = status.to_string();
            if let Some(sig) = tx_sig {
                if status == "withdrawn" {
                    note.withdraw_tx_sig = Some(sig.to_string());
                }
            }
            self.save()?;
            return Ok(true);
        }
        Ok(false)
    }

    /// Delete a note
    pub fn delete(&mut self, id: &str) -> bool {
        let len_before = self.notes.len();
        self.notes.retain(|n| n.id != id);
        
        if self.notes.len() < len_before {
            let _ = self.save();
            return true;
        }
        false
    }

    /// Export notes to file
    pub fn export(&self, path: &str) -> Result<()> {
        let data = serde_json::to_string_pretty(&self.notes)?;
        fs::write(path, data)?;
        Ok(())
    }

    /// Import notes from file
    pub fn import(&mut self, path: &str) -> Result<usize> {
        let data = fs::read_to_string(path)?;
        let imported: Vec<Note> = serde_json::from_str(&data)?;
        
        let existing_ids: std::collections::HashSet<_> = 
            self.notes.iter().map(|n| n.commitment.clone()).collect();
        
        let mut count = 0;
        for note in imported {
            if !existing_ids.contains(&note.commitment) {
                self.notes.push(note);
                count += 1;
            }
        }
        
        self.save()?;
        Ok(count)
    }

    /// Get notes by status
    pub fn get_by_status(&self, status: &str) -> Vec<&Note> {
        self.notes.iter().filter(|n| n.status == status).collect()
    }
}

/// Generate a unique note ID
pub fn generate_note_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis();
    let random: u32 = rand::random();
    format!("note_{}_{:x}", timestamp, random)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_note_store() {
        let mut store = NoteStore::default();
        
        let note = Note {
            id: "test_note".to_string(),
            amount: 1_000_000_000,
            privkey: "abc".to_string(),
            pubkey: "def".to_string(),
            blinding: "123".to_string(),
            commitment: "456".to_string(),
            leaf_index: 0,
            status: "deposited".to_string(),
            created_at: 0,
            deposit_tx_sig: None,
            withdraw_tx_sig: None,
        };
        
        store.notes.push(note);
        assert_eq!(store.notes.len(), 1);
        assert_eq!(store.get_by_status("deposited").len(), 1);
    }
}
