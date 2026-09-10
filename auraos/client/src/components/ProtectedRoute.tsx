import { Navigate } from 'react-router-dom'
import { useAuth } from '../contexts/AuthContext'

interface ProtectedRouteProps {
  children: React.ReactNode
  roles?: string[]
  superAdminOnly?: boolean
}

const ProtectedRoute: React.FC<ProtectedRouteProps> = ({ children, roles, superAdminOnly }) => {
  const { isAuthenticated, isLoading, user } = useAuth()

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="h-10 w-10 rounded-full border-2 border-gray-200 border-t-indigo-600 animate-spin" />
      </div>
    )
  }

  if (!isAuthenticated) {
    return <Navigate to="/login" replace />
  }

  if (superAdminOnly && user && !user.isSuperAdmin) {
    return <Navigate to="/" replace />
  }

  if (roles && roles.length > 0 && user && !roles.includes(user.role)) {
    return <Navigate to="/" replace />
  }

  return <>{children}</>
}

export default ProtectedRoute
