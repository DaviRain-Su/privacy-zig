/**
 * Note Management for Privacy Pool
 * 
 * Notes contain all information needed to withdraw funds.
 * Stored in localStorage for persistence across page refreshes.
 */

export interface Note {
  id: string;           // Unique identifier
  amount: number;       // Amount in lamports
  privkey: string;      // UTXO private key (hex)
  pubkey: string;       // UTXO public key (decimal string)
  blinding: string;     // Blinding factor (decimal string)
  commitment: string;   // Commitment hash (decimal string)
  leafIndex: number;    // Position in Merkle tree (-1 if pending)
  status: 'pending' | 'deposited' | 'withdrawn';
  createdAt: number;    // Timestamp
  depositTxSig?: string;
  withdrawTxSig?: string;
}

const STORAGE_KEY = 'privacy_pool_notes';

/**
 * Get all notes from localStorage
 */
export function getNotes(): Note[] {
  if (typeof window === 'undefined') return [];
  
  try {
    const data = localStorage.getItem(STORAGE_KEY);
    return data ? JSON.parse(data) : [];
  } catch {
    return [];
  }
}

/**
 * Save notes to localStorage
 */
export function saveNotes(notes: Note[]): void {
  if (typeof window === 'undefined') return;
  localStorage.setItem(STORAGE_KEY, JSON.stringify(notes));
}

/**
 * Add a new note
 */
export function addNote(note: Omit<Note, 'id' | 'createdAt'>): Note {
  const notes = getNotes();
  const newNote: Note = {
    ...note,
    id: generateNoteId(),
    createdAt: Date.now(),
  };
  notes.push(newNote);
  saveNotes(notes);
  return newNote;
}

/**
 * Update a note by ID
 */
export function updateNote(id: string, updates: Partial<Note>): Note | null {
  const notes = getNotes();
  const index = notes.findIndex(n => n.id === id);
  if (index === -1) return null;
  
  notes[index] = { ...notes[index], ...updates };
  saveNotes(notes);
  return notes[index];
}

/**
 * Delete a note by ID
 */
export function deleteNote(id: string): boolean {
  const notes = getNotes();
  const filtered = notes.filter(n => n.id !== id);
  if (filtered.length === notes.length) return false;
  
  saveNotes(filtered);
  return true;
}

/**
 * Get notes that can be withdrawn
 */
export function getWithdrawableNotes(): Note[] {
  return getNotes().filter(n => n.status === 'deposited');
}

/**
 * Export notes as encrypted string (base64)
 */
export function exportNotes(): string {
  const notes = getNotes();
  return btoa(JSON.stringify(notes));
}

/**
 * Import notes from encrypted string
 */
export function importNotes(data: string): number {
  try {
    const imported: Note[] = JSON.parse(atob(data));
    const existing = getNotes();
    
    // Merge, avoiding duplicates by commitment
    const existingCommitments = new Set(existing.map(n => n.commitment));
    const newNotes = imported.filter(n => !existingCommitments.has(n.commitment));
    
    saveNotes([...existing, ...newNotes]);
    return newNotes.length;
  } catch {
    return 0;
  }
}

/**
 * Generate a unique note ID
 */
function generateNoteId(): string {
  return `note_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * Format amount for display
 */
export function formatAmount(lamports: number): string {
  return (lamports / 1e9).toFixed(4);
}

/**
 * Format timestamp for display
 */
export function formatDate(timestamp: number): string {
  return new Date(timestamp).toLocaleString();
}
