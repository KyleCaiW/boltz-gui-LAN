import { useState } from 'react'

const SequenceInput = ({ sequence, onUpdate, onRemove }) => {
  const [isDragOver, setIsDragOver] = useState(false)
  const [isUploading, setIsUploading] = useState(false)

  const handleFileUpload = async (file) => {
    if (!file || !file.name.endsWith('.a3m')) {
      alert('Please select a valid .a3m file')
      return
    }

    setIsUploading(true)
    try {
      const formData = new FormData()
      formData.append('file', file)

      const response = await fetch('/upload_msa', {
        method: 'POST',
        body: formData
      })

      if (!response.ok) {
        const error = await response.json().catch(() => ({}))
        throw new Error(error.detail || 'Upload failed')
      }

      const result = await response.json()
      onUpdate({ msa: result.path, msa_filename: result.filename })
    } catch (error) {
      console.error('MSA upload failed:', error)
      alert(`MSA upload failed: ${error.message}`)
    } finally {
      setIsUploading(false)
    }
  }

  const handleDragOver = (e) => {
    e.preventDefault()
    setIsDragOver(true)
  }

  const handleDragLeave = (e) => {
    e.preventDefault()
    setIsDragOver(false)
  }

  const handleDrop = (e) => {
    e.preventDefault()
    setIsDragOver(false)
    const files = e.dataTransfer.files
    if (files.length > 0) {
      handleFileUpload(files[0])
    }
  }

  const handleFileChange = (e) => {
    const file = e.target.files[0]
    if (file) {
      handleFileUpload(file)
    }
  }
  const getSequenceIcon = (type) => {
    switch (type) {
      case 'protein': return '🧬'
      case 'dna': return '🧬'
      case 'rna': return '🧬'
      case 'ligand': return '💊'
      default: return '🧬'
    }
  }

  const getSequenceColor = (type) => {
    switch (type) {
      case 'protein': return 'glass-card-blue'
      case 'dna': return 'glass-card-green'
      case 'rna': return 'glass-card-purple'
      case 'ligand': return 'glass-card-orange'
      default: return 'glass-card-gray'
    }
  }

  return (
    <div className={`rounded-xl p-6 shadow-xl transition-all duration-300 hover:scale-[1.02] ${getSequenceColor(sequence.entity_type)}`}>
      <div className="flex items-center justify-between mb-4">
        <div className="flex items-center space-x-2">
          <span className="text-xl">{getSequenceIcon(sequence.entity_type)}</span>
          <h3 className="font-medium text-gray-800 capitalize">
            {sequence.entity_type} Sequence
          </h3>
        </div>
        <button
          type="button"
          onClick={onRemove}
          className="text-red-500 hover:text-red-700 text-sm"
        >
          Remove
        </button>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {/* Chain ID */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Chain ID *
          </label>
          <input
            type="text"
            value={sequence.chainId}
            onChange={(e) => onUpdate({ chainId: e.target.value })}
            className="form-input"
            placeholder="e.g., A"
            maxLength={5}
          />
        </div>

        {/* Entity Type specific fields */}
        {sequence.entity_type === 'ligand' ? (
          <>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                SMILES
              </label>
              <input
                type="text"
                value={sequence.smiles}
                onChange={(e) => onUpdate({ smiles: e.target.value })}
                className="form-input"
                placeholder="e.g., N[C@@H](Cc1ccc(O)cc1)C(=O)O"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                CCD Code
              </label>
              <input
                type="text"
                value={sequence.ccd}
                onChange={(e) => onUpdate({ ccd: e.target.value })}
                className="form-input"
                placeholder="e.g., TYR"
              />
            </div>
            <div className="md:col-span-2">
              <label className="flex items-center space-x-2">
                <input
                  type="checkbox"
                  checked={sequence.cyclic}
                  onChange={(e) => onUpdate({ cyclic: e.target.checked })}
                  className="w-4 h-4 text-blue-600 border-gray-300 rounded focus:ring-blue-500"
                />
                <span className="text-sm text-gray-700">Cyclic</span>
              </label>
            </div>
          </>
        ) : (
          <>
            <div className="md:col-span-2">
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Sequence *
              </label>
              <textarea
                value={sequence.sequence}
                onChange={(e) => onUpdate({ sequence: e.target.value })}
                className="form-textarea"
                placeholder={`Enter ${sequence.entity_type} sequence...`}
                rows={4}
              />
            </div>
            <div className="md:col-span-2">
              {sequence.entity_type === 'protein' && (
                <label className="flex items-start space-x-2 mb-3">
                  <input
                    type="checkbox"
                    checked={sequence.msa === 'empty'}
                    onChange={(e) => onUpdate(e.target.checked
                      ? { msa: 'empty', msa_filename: '' }
                      : { msa: '', msa_filename: '' })}
                    className="w-4 h-4 mt-0.5 text-blue-600 border-gray-300 rounded focus:ring-blue-500"
                  />
                  <span className="text-sm text-gray-700">
                    No MSA (single sequence mode)
                    <span className="block text-xs text-gray-500">
                      Skips the MSA server entirely and predicts from this sequence alone.
                    </span>
                  </span>
                </label>
              )}
            </div>
            {sequence.msa !== 'empty' && (
            <div className="md:col-span-2">
              <label className="block text-sm font-medium text-gray-700 mb-3">
                MSA File (.a3m) - Optional
              </label>
              
              {/* Drag and Drop Zone */}
              <div
                className={`relative rounded-xl p-6 border-2 border-dashed transition-all duration-300 ${
                  isDragOver 
                    ? 'border-blue-400 scale-105' 
                    : sequence.msa 
                      ? 'border-green-400' 
                      : 'border-gray-300'
                }`}
                style={{
                  background: isDragOver 
                    ? 'rgba(59, 130, 246, 0.1)' 
                    : sequence.msa 
                      ? 'rgba(34, 197, 94, 0.1)' 
                      : 'rgba(255, 255, 255, 0.1)',
                  backdropFilter: 'blur(8px)'
                }}
                onDragOver={handleDragOver}
                onDragLeave={handleDragLeave}
                onDrop={handleDrop}
              >
                <input
                  type="file"
                  accept=".a3m"
                  onChange={handleFileChange}
                  disabled={isUploading}
                  className="absolute inset-0 w-full h-full opacity-0 cursor-pointer"
                  id={`msa-upload-${sequence.id}`}
                />
                
                <div className="text-center">
                  {sequence.msa ? (
                    // File uploaded state
                    <div className="space-y-3">
                      <div className="flex items-center justify-center">
                        <svg className="w-12 h-12 text-green-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
                        </svg>
                      </div>
                      <div>
                        <p className="text-green-700 font-semibold">File uploaded successfully!</p>
                        <p className="text-sm text-green-600 font-mono mt-1">
                          {sequence.msa_filename || sequence.msa}
                        </p>
                      </div>
                      <button
                        type="button"
                        onClick={() => onUpdate({ msa: '', msa_filename: '' })}
                        className="text-red-500 hover:text-red-700 text-sm font-medium transition-colors duration-200"
                      >
                        Remove file
                      </button>
                    </div>
                  ) : (
                    // Upload state
                    <div className="space-y-3">
                      <div className="flex items-center justify-center">
                        <svg className={`w-12 h-12 transition-colors duration-300 ${
                          isDragOver ? 'text-blue-500' : 'text-gray-400'
                        }`} fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12" />
                        </svg>
                      </div>
                      <div>
                        <p className={`font-semibold transition-colors duration-300 ${
                          isDragOver ? 'text-blue-700' : 'text-gray-700'
                        }`}>
                          {isUploading
                            ? 'Uploading MSA...'
                            : isDragOver
                              ? 'Drop your .a3m file here'
                              : 'Drag & drop your .a3m file here'}
                        </p>
                        <p className="text-sm text-gray-500 mt-1">
                          or{' '}
                          <label 
                            htmlFor={`msa-upload-${sequence.id}`}
                            className="text-blue-600 hover:text-blue-800 font-medium cursor-pointer underline"
                          >
                            browse to select
                          </label>
                        </p>
                      </div>
                      <div className="text-xs text-gray-500 space-y-1">
                        <p>• Multiple Sequence Alignment file (.a3m)</p>
                      </div>
                    </div>
                  )}
                </div>
              </div>
            </div>
            )}
            {sequence.entity_type === 'protein' && (
              <div className="md:col-span-2">
                <label className="flex items-center space-x-2">
                  <input
                    type="checkbox"
                    checked={sequence.cyclic}
                    onChange={(e) => onUpdate({ cyclic: e.target.checked })}
                    className="w-4 h-4 text-blue-600 border-gray-300 rounded focus:ring-blue-500"
                  />
                  <span className="text-sm text-gray-700">Cyclic</span>
                </label>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  )
}

export default SequenceInput 
