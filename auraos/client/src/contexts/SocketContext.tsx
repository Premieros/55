import React, { createContext, useContext, useEffect, useState, ReactNode, useCallback } from 'react'
import { io, Socket } from 'socket.io-client'
import { useAuth } from './AuthContext'

interface SocketContextType {
  socket: Socket | null
  isConnected: boolean
  emit: (event: string, data?: any) => void
  on: (event: string, callback: (data: any) => void) => void
  off: (event: string) => void
}

const SocketContext = createContext<SocketContextType | undefined>(undefined)

export const useSocket = () => {
  const context = useContext(SocketContext)
  if (context === undefined) {
    throw new Error('useSocket must be used within a SocketProvider')
  }
  return context
}

interface SocketProviderProps {
  children: ReactNode
}

export const SocketProvider: React.FC<SocketProviderProps> = ({ children }) => {
  const [socket, setSocket] = useState<Socket | null>(null)
  const [isConnected, setIsConnected] = useState(false)
  const { token, user } = useAuth()

  useEffect(() => {
    const socketUrl = (import.meta.env.VITE_SOCKET_URL || '').trim()
    const socketPath = (import.meta.env.VITE_SOCKET_PATH || '/socket.io').trim()

    // Static previews may intentionally omit realtime. In that case, do not
    // accidentally connect Socket.IO to the GitHub Pages origin.
    if (!socketUrl || !token || !user) {
      if (socket) {
        socket.close()
        setSocket(null)
      }
      setIsConnected(false)
      return
    }

    const newSocket = io(socketUrl, {
      path: socketPath,
      transports: ['websocket'],
      auth: {
        token
      },
      reconnection: true,
      reconnectionDelay: 1000,
      reconnectionDelayMax: 5000,
      reconnectionAttempts: 5
    })

    newSocket.on('connect', () => {
      console.log('[Socket] Connected')
      setIsConnected(true)
      // Join restaurant room for real-time updates
      if (user.restaurantId) {
        newSocket.emit('join_restaurant', { restaurantId: user.restaurantId })
      }
    })

    newSocket.on('disconnect', () => {
      console.log('[Socket] Disconnected')
      setIsConnected(false)
    })

    newSocket.on('connect_error', (error: any) => {
      console.error('[Socket] Connection error:', error)
      setIsConnected(false)
    })

    setSocket(newSocket)

    return () => {
      newSocket.close()
    }
  }, [token, user])

  const emit = useCallback((event: string, data?: any) => {
    if (socket) {
      socket.emit(event, data)
    }
  }, [socket])

  const on = useCallback((event: string, callback: (data: any) => void) => {
    if (socket) {
      socket.on(event, callback)
    }
  }, [socket])

  const off = useCallback((event: string) => {
    if (socket) {
      socket.off(event)
    }
  }, [socket])

  const value: SocketContextType = {
    socket,
    isConnected,
    emit,
    on,
    off
  }

  return <SocketContext.Provider value={value}>{children}</SocketContext.Provider>
}
