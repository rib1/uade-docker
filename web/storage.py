"""
Storage abstraction for UADE Web Player
Supports local filesystem and GCS/S3 backends using fsspec
"""
import fsspec

class FSStorage:
    def __init__(self, base_uri, fs_kwargs=None):
        """
        base_uri: e.g. '/tmp/modules' for local, 's3://bucket/path' for S3, 'gcs://bucket/path' for GCS
        fs_kwargs: dict of extra arguments for fsspec.filesystem (credentials, etc)
        """
        self.base_uri = base_uri.rstrip('/')
        self.fs, self.root = self._get_fs_and_root(base_uri, fs_kwargs or {})

    def _get_fs_and_root(self, uri, fs_kwargs):
        if uri.startswith('s3://'):
            fs = fsspec.filesystem('s3', **fs_kwargs)
            root = uri[5:]
        elif uri.startswith('gcs://'):
            fs = fsspec.filesystem('gcs', **fs_kwargs)
            root = uri[6:]
        else:
            fs = fsspec.filesystem('file')
            root = uri
        return fs, root

    def open(self, rel_path, mode):
        """Open file for reading/writing (binary mode recommended)"""
        path = f"{self.root}/{rel_path}".replace('//', '/')
        return self.fs.open(path, mode)

    def size(self, rel_path):
        """Get file size in bytes"""
        path = f"{self.root}/{rel_path}".replace('//', '/')
        return self.fs.size(path)

    def save(self, rel_path, data):
        """Save binary data to file"""
        path = f"{self.root}/{rel_path}".replace('//', '/')
        with self.fs.open(path, "wb") as f:
            f.write(data)
        return path

    def load(self, rel_path):
        """Load binary data from file"""
        path = f"{self.root}/{rel_path}".replace('//', '/')
        with self.fs.open(path, "rb") as f:
            return f.read()

    def exists(self, rel_path):
        """Check if file exists"""
        path = f"{self.root}/{rel_path}".replace('//', '/')
        return self.fs.exists(path)

    def delete(self, rel_path):
        """Delete file if exists"""
        path = f"{self.root}/{rel_path}".replace('//', '/')
        if self.fs.exists(path):
            self.fs.rm(path)

    def list(self, subdir=""):
        """List files in subdir (relative to base_uri)"""
        dir_path = f"{self.root}/{subdir}".replace('//', '/') if subdir else self.root
        if not self.fs.exists(dir_path):
            return []
        return [p for p in self.fs.ls(dir_path, detail=False) if self.fs.isfile(p)]
