import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    port: 6868,
    strictPort: true,
    proxy: {
      '/api': 'http://localhost:6969',
      '/predict': 'http://localhost:6969',
      '/upload_msa': 'http://localhost:6969',
      '/upload_template': 'http://localhost:6969',
      '/health': 'http://localhost:6969'
    }
  },
  preview: {
    host: '0.0.0.0',
    port: 6868,
    strictPort: true
  }
})
