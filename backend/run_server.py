import uvicorn
import socket
from app import app

def get_lan_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]
    except OSError:
        return "<LAN-IP>"

if __name__ == "__main__":
    print("Starting Boltz GUI Server...")
    print("Server will be available at: http://localhost:6969")
    print(f"LAN access: http://{get_lan_ip()}:6969")
    print("API documentation: http://localhost:6969/docs")
    print("Health check: http://localhost:6969/health")
    print("Press Ctrl+C to stop the server")
    
    uvicorn.run(
        "app:app",
        host="0.0.0.0",
        port=6969,
        reload=True,
        log_level="info"
    ) 
